// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// What happened in the game and on its screens, told to the app around the game: the screens and GameController post an
/// event where it happens, synchronously, and `GameEvents.observe` (supplied by the app, outside the game's code) sees it.
/// The game reads nothing back - an event changes no state of the game.
enum GameEvent {
    /// A screen, or a page of one, came up
    case screen(String)
    case pediaOpened
    case gameStarted(GameState, source: String)
    case gameLoaded(GameState, source: String)
    case gameSaved(turn: Int)
    case gameEnded(GameState)
    /// A new turn arrives on the world screen (before it replaces the one shown)
    case turnArrived(old: GameState, new: GameState)
    /// The new turn is shown
    case turnShown(GameController)
    case tradeProposed(turn: Int)
    case tradeAccepted
    case unitAttacked(unit: String)
    case cityFounded(turn: Int, cityCount: Int)
    case productionChosen(item: String, isUnit: Bool)
    case productionBought(item: String, isUnit: Bool, stat: String)
    case techChosen(String)
    case techQueued(String, free: Bool)
    case policyAdopted(item: String, isBranch: Bool)
    case peaceMade(turn: Int, withCityState: Bool)
    case warDeclared(turn: Int, onCityState: Bool)
    case languageChanged(String, source: String?)
    case tutorialTaskDone(String)
    /// A tap on an entry point that is not open in this build (`mods`: the mods one, else online multiplayer)
    case unavailableTapped(mods: Bool, place: String)
}

enum GameEvents {
    static func post(_ event: GameEvent) { observe(event) }
}

extension View {
    /// Posts `.screen(name)` as the view appears
    func screenShown(_ name: String) -> some View { onAppear { GameEvents.post(.screen(name)) } }
}
