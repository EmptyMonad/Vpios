// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UIKit

/// Unciv's F1-F12 bindings (Civilopedia, the overview pages, Social Policies, Technology Tree, Victory status, Quick
/// Save / Quick Load): SwiftUI's KeyEquivalent has no function keys, so the application reads them off the key presses
/// it sends (EpochsApplication.sendEvent) and hands them to the screens that registered for them - newest first, the
/// first that takes the key consumes it, as a screen pushed over another has the key before the one below it.
@MainActor
enum FunctionKeys {
    private static var handlers: [(id: UUID, handle: (KeySpec) -> Bool)] = []
    static func register(_ id: UUID, _ handle: @escaping (KeySpec) -> Bool) {
        handlers.removeAll { $0.id == id }
        handlers.append((id, handle))
    }
    static func unregister(_ id: UUID) { handlers.removeAll { $0.id == id } }
    @discardableResult
    static func dispatch(_ spec: KeySpec) -> Bool {
        for h in handlers.reversed() where h.handle(spec) { return true }
        return false
    }

    /// Unciv Input.Keys.F1..F12 → the KeySpec name the bindings store ("F1".."F12").
    static let names: [UIKeyboardHIDUsage: String] = [
        .keyboardF1: "F1", .keyboardF2: "F2", .keyboardF3: "F3", .keyboardF4: "F4", .keyboardF5: "F5", .keyboardF6: "F6",
        .keyboardF7: "F7", .keyboardF8: "F8", .keyboardF9: "F9", .keyboardF10: "F10", .keyboardF11: "F11", .keyboardF12: "F12",
    ]
    static func modifiers(_ flags: UIKeyModifierFlags) -> EventModifiers {
        var m: EventModifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.alternate) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        return m
    }

    /// A sheet, full-screen cover, popover or confirmation dialog presented over the root view (Unciv: another screen
    /// pushed over the one whose keys these are, or a popup open on it).
    static var rootIsCovered: Bool {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first { $0.isKeyWindow }
        return window?.rootViewController?.presentedViewController != nil
    }
}

/// The application object (NSPrincipalClass in Info.plist): it sees every key press before it is dispatched, which is
/// where the function keys are picked up. Every event goes on to UIKit unchanged.
@objc(EpochsApplication)
final class EpochsApplication: UIApplication {
    override func sendEvent(_ event: UIEvent) {
        if let presses = event as? UIPressesEvent {
            for press in presses.allPresses where press.phase == .began {
                guard let key = press.key, let name = FunctionKeys.names[key.keyCode] else { continue }
                FunctionKeys.dispatch(KeySpec(name, FunctionKeys.modifiers(key.modifierFlags)))
            }
        }
        super.sendEvent(event)
    }
}
