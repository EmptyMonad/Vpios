// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv `UncivGame.Current.screen is CityScreen` - a global there too: ConstructionAutomation.chooseNextConstruction gives
/// no "[city] has started working on [x]" while the city screen is up ("might be a buying spree"). GameController.showCity
/// keeps it; the turn's thread reads it as Unciv's reads the screen.
var epochsCityScreenOpen = false

/// Unciv "Hide system status and navigation bars" (GameSettings.androidHideSystemUi, on by default): AndroidDisplay
/// setSystemUiVisibility hides the status and navigation bars with IMMERSIVE_STICKY, so a swipe in from an edge reaches the
/// game and only brings the bars back, and the checkbox (AdvancedTab) applies at once. iOS's counterparts: the status bar and
/// the home indicator hidden, and the system's edge gestures deferred on every edge - the first swipe goes to the game, the
/// system's own needs a second. Off, the system keeps both. Every sheet and full-screen cover is a hosting controller of its
/// own that UIKit asks separately, so each presentation's root carries this too.
struct ImmersiveSystemUI: ViewModifier {
    @AppStorage("epochs.hideSystemBars") private var hideSystemBars = true   // UserSettings.hideSystemBars
    func body(content: Content) -> some View {
        content
            .statusBarHidden(hideSystemBars)
            .persistentSystemOverlays(hideSystemBars ? .hidden : .automatic)
            .defersSystemGestures(on: hideSystemBars ? .all : [])
            // a sheet or full-screen cover inherits its presenter's environment but is not scaled by VirtualCanvas
            .environment(\.onVirtualCanvas, false)
            .environment(\.stageWidth, 0)
            .environment(\.cutoutBleed, EdgeInsets())
    }
}

extension View {
    /// Unciv "Hide system status and navigation bars" on this hosting controller (ImmersiveSystemUI)
    func immersiveSystemUI() -> some View { modifier(ImmersiveSystemUI()) }
}

/// Switches between the main menu and a running game.
struct RootView: View {
    init() { Theme.recomputeScale() }   // Unciv sizes its UI against the screen before the first frame
    @State var controller: GameController? = nil
    /// A message the main menu shows on its return (a load UncivGame.loadGame refused)
    @State var menuMessage: String? = nil
    @State var pickLanguage = LanguagePickerScreen.shouldShow
    /// The app's own screens between the language picker and the main menu (appOwnScreen, outside the game's code)
    @State var appFlow = AppFlowState()

    var body: some View {
        VirtualCanvas {
        ZStack {
            if pickLanguage {
                // Unciv: the very first launch asks for the language before the main menu.
                LanguagePickerScreen(onDone: { pickLanguage = false })
            } else if appFlow.showsOwnScreen {
                appOwnScreen
            } else if let c = controller {
                GameView(controller: c, onQuit: { menuMessage = c.mainMenuMessage; controller = nil; GameController.current = nil }, onStart: { state in load(state) })
                    .id(ObjectIdentifier(c))
            } else {
                MainMenuView(onStart: { state in load(state) }, message: $menuMessage)
            }
        }
        .preferredColorScheme(.dark)
        }
        .immersiveSystemUI()
        .modifier(AppFlowHooks(root: self))
        // Unciv UncivGame.create: the Menu / Ambient music starts once, before the language picker or the main menu (going
        // through Audio.shared starts the audio session's setup on its queue, which the track waits for); a return to the
        // main menu keeps the game's track playing.
        // Unciv MainMenuScreen's init: SoundPlayer.initializeForMainMenu - the effects preloaded in the background, here as
        // the app appears, a game loaded at launch included
        .onAppear { if !RootView.musicStarted { RootView.musicStarted = true; Audio.shared.startMusic(); Audio.shared.initializeForMainMenu() } }
        .launchArgumentHooks(self)
        // Unciv UncivGame.create: "Check if the server is available in case the feature set has changed"
        .task { await Multiplayer.checkServerStatus() }
    }
    nonisolated(unsafe) private static var musicStarted = false

    /// Unciv UncivGame.loadGame: an online game that allows no spectators refuses a player who holds none of its seats
    /// ("You are not allowed to spectate!") - the message goes to the main menu. The controller shown is the app's current
    /// game (Unciv UncivGame.gameInfo), which a turn still running for the one before no longer arrives in.
    func load(_ state: GameState) {
        var shown: GameController? = nil
        do { try Multiplayer.checkSpectate(state); menuMessage = nil; shown = GameController(state: state) }
        catch { menuMessage = MultiplayerHelpers.loadExceptionMessage(error) }
        controller = shown
        GameController.current = shown
    }
}
