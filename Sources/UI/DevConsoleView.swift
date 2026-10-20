// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv DevConsolePopup: input line with autocomplete (⇥) and history (↑/↓) buttons, coloured response label.
struct DevConsoleView: View {
    @ObservedObject var controller: GameController
    let onClose: () -> Void
    @State private var input = ""
    @State private var response: DevConsole.Response? = nil
    @State private var historyIndex = UserSettings.consoleCommandHistory.count
    /// Unciv DevConsolePopup: the "Keep open" checkbox, bound to GameSettings.keepConsoleOpen.
    @State private var keepOpen = UserSettings.keepConsoleOpen
    /// Unciv `civ remove` with "Keep open": the annihilation ConfirmPopup shown over the console
    @State private var annihilation: GameController.IdentifiedAnnihilation? = nil
    @FocusState private var focused: Bool

    var body: some View {
        let console = DevConsole(controller: controller)
        ThemedSheet(L("Developer Console"), subtitle: nil, onClose: onClose) {
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Keep open", isOn: $keepOpen).tint(Theme.gold).font(Theme.body)
                        .onChange(of: keepOpen) { _, v in UserSettings.keepConsoleOpen = v }
                    HStack(spacing: 6) {
                        TextField("", text: $input).textFieldStyle(.roundedBorder).font(.system(size: 14, design: .monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never).focused($focused)
                            .onSubmit { run(console) }
                        Button {
                            if let a = console.autocomplete(input) { input = a }
                            response = console.completionMessage.map { DevConsole.Response(kind: .hint, message: $0) }   // the label cleared, or the matches
                        } label: { Image(systemName: "arrow.right.to.line") }.buttonStyle(ThemedButtonStyle(compact: true))
                        Button { navigate(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(ThemedButtonStyle(compact: true))
                        Button { navigate(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(ThemedButtonStyle(compact: true))
                        Button { run(console) } label: { Image(systemName: "return") }.buttonStyle(ThemedButtonStyle(filled: true, compact: true))
                    }
                    if let r = response {
                        Text(r.message.isEmpty && r.kind == .ok ? "OK" : r.message).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(r.kind == .ok ? Theme.good : r.kind == .error ? Theme.danger : Theme.gold)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onAppear { focused = true }
        .confirmationDialog(annihilation?.message ?? "", isPresented: Binding(get: { annihilation != nil }, set: { if !$0 { annihilation = nil } }), titleVisibility: .visible) {
            Button(L("Yes"), role: .destructive) { if let a = annihilation, !controller.isProcessing { controller.state.annihilateCiv(a.civId); controller.refresh() }; annihilation = nil }
            Button(L("Cancel"), role: .cancel) {}   // Unciv ConfirmPopup's "Cancel" (the system's stays in English)
        }
    }

    /// Unciv DevConsolePopup.onEnter: the command runs first; only a command that answers OK goes into the history,
    /// then the console closes (or, kept open, clears the line). An error or a hint stays on screen with the line.
    private func run(_ console: DevConsole) {
        let line = input.trimmingCharacters(in: .whitespaces)
        // the world screen's game is not changed while the next turn is being played on its clone (Unciv canChangeState)
        guard !controller.isProcessing else { response = DevConsole.Response(kind: .error, message: L("Working...")); return }
        let result = console.handle(line)
        // Unciv DevConsolePopup.onEnter: an OK closes (or, kept open, clears the line) without touching the response label
        guard result.kind == .ok else { response = result; return }
        addHistory(input)
        // Unciv `civ remove`: its ConfirmPopup opens on the world screen, over a console that stays open
        if let a = controller.pendingAnnihilation {
            controller.pendingAnnihilation = nil
            let item = GameController.IdentifiedAnnihilation(civId: a.civId, message: a.message)
            if UserSettings.keepConsoleOpen { annihilation = item } else { controller.afterSheetDismiss { [controller] in controller.confirmAnnihilation = item } }
        }
        if !UserSettings.keepConsoleOpen { controller.showDevConsole = false } else { input = "" }
    }
    /// Unciv DevConsolePopup.addHistory: no blank lines, no repeat of the last entry (ignoring case); at 42 entries the
    /// case-insensitive copies of the line go first, then the oldest entry.
    private func addHistory(_ text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        var history = UserSettings.consoleCommandHistory
        if let last = history.last, last.caseInsensitiveCompare(text) == .orderedSame { return }
        if history.count >= 42 {
            history.removeAll { $0.caseInsensitiveCompare(text) == .orderedSame }
            if history.count >= 42 { history.remove(at: 0) }
        }
        history.append(text)
        UserSettings.consoleCommandHistory = history
        historyIndex = history.count
    }
    private func navigate(_ delta: Int) {
        let h = UserSettings.consoleCommandHistory
        guard !h.isEmpty else { return }
        // Unciv navigateHistory: `(currentHistoryEntry + delta).coerceIn(history.indices)` - never past either end
        historyIndex = min(h.count - 1, max(0, historyIndex + delta))
        input = h[historyIndex]
    }
}
