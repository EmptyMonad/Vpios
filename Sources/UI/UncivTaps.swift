// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import QuartzCore

/// Unciv ActivationListener over libGDX GestureDetector.touchUp: every lift inside the tap square is a tap, and its count
/// carries on from the previous lift on the same actor while it comes within `multiTapInterval` (GameSettings, 0.25 s) of
/// that lift and inside the 20-unit half square around it; otherwise the count starts again at 1. ActivationTypes maps a
/// count of 1 to Tap, fired at once, and 2 to Doubletap; 3 and more (Tripletap, which nothing handles) do nothing and do
/// not start the count over. SwiftUI's `.onTapGesture(count: 2)` beside `.onTapGesture` held every single tap back until
/// the double tap had failed.
struct UncivTaps: ViewModifier {
    /// Whether two lifts landed on the same Unciv actor - a view that stands for several (a Canvas of tiles) says so;
    /// a view that is one actor itself leaves it true
    var sameTarget: (CGPoint, CGPoint) -> Bool = { _, _ in true }
    /// The flag an uncivLongPress on the same view sets when its long press fires
    var longPressFired: Binding<Bool>? = nil
    let onTap: (CGPoint) -> Void
    let onDoubleTap: (CGPoint) -> Void
    /// GestureDetector's lastTapTime / lastTapX / lastTapY and tapCount
    @State private var lastLift: (time: CFTimeInterval, point: CGPoint, count: Int)? = nil
    @Environment(\.onVirtualCanvas) private var onCanvas

    /// UncivActorGestureListener: ActorGestureListener(halfTapSquareSize = 20f, ...) - 20 stage units, on our canvas (the
    /// stage's 600 units high are its 393 points on Small)
    static let halfTapSquare: CGFloat = 20 * 393 / 600

    func body(content: Content) -> some View {
        // 20 stage units in this view's points: a sheet or full-screen cover is not scaled by VirtualCanvas, so a canvas
        // point there is uiScale screen points
        let half = Self.halfTapSquare * (onCanvas ? 1 : Theme.uiScale)
        return content.onTapGesture { p in
            // GestureDetector.touchUp: `if (longPressFired) return false` - the lift ending a long press is no tap and
            // leaves the tap count alone
            if let fired = longPressFired, fired.wrappedValue { fired.wrappedValue = false; return }
            let now = CACurrentMediaTime()
            var count = 1
            // GestureDetector.touchUp: `if (... nanoTime - lastTapTime > tapCountInterval || !isWithinTapRectangle(x, y,
            // lastTapX, lastTapY)) tapCount = 0; tapCount++`
            if let last = lastLift, now - last.time <= UserSettings.multiTapInterval,
               abs(p.x - last.point.x) < half, abs(p.y - last.point.y) < half,
               sameTarget(last.point, p) {
                count = last.count + 1
            }
            lastLift = (now, p, count)
            // ActivationListener.tap: the ActivationTypes entry whose tapCount is the count - Tap or Doubletap, none past 2
            if count == 1 { onTap(p) } else if count == 2 { onDoubleTap(p) }
        }
    }
}

extension View {
    /// Unciv onClick + onDoubleClick on one actor (see UncivTaps)
    func uncivTaps(onTap: @escaping () -> Void, onDoubleTap: @escaping () -> Void) -> some View {
        modifier(UncivTaps(onTap: { _ in onTap() }, onDoubleTap: { _ in onDoubleTap() }))
    }
    /// Unciv onClick + onDoubleClick beside an onLongPress (uncivLongPress with the same `longPressFired`): the long
    /// press's lift is no tap
    func uncivTaps(longPressFired: Binding<Bool>, onTap: @escaping () -> Void, onDoubleTap: @escaping () -> Void) -> some View {
        modifier(UncivTaps(longPressFired: longPressFired, onTap: { _ in onTap() }, onDoubleTap: { _ in onDoubleTap() }))
    }
    /// Unciv onClick + onDoubleClick for a view drawing several actors: `sameTarget` tells whether two lifts hit the same one
    func uncivTaps(sameTarget: @escaping (CGPoint, CGPoint) -> Bool, onTap: @escaping (CGPoint) -> Void, onDoubleTap: @escaping (CGPoint) -> Void) -> some View {
        modifier(UncivTaps(sameTarget: sameTarget, onTap: onTap, onDoubleTap: onDoubleTap))
    }
}
