// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import SpriteKit
import UIKit

/// Unciv NotificationsScroll is a ScrollPane with `touchable = Touchable.childrenOnly` (NotificationsScroll.init): the pane
/// never takes a touch itself, only what it holds does. Its notificationsTable and the per-category tables are plain Tables,
/// childrenOnly as well, and the actors that answer are the ListItem (`touchable = Touchable.enabled`, its padding included -
/// "a large click area with no gap in between each message item") and the CategoryHeader (`touchable = Touchable.enabled //
/// stop clicks going through to map`). Everything else in the pane - the room left of an entry narrower than the widest one,
/// the pane's empty ends - reaches the map: a tap there selects a tile and a drag pans the map. A drag that starts on an entry
/// bubbles up to the ScrollPane's flick-scroll listener and scrolls the list, and a tap on it runs `notification.execute`.
///
/// The pane is as high as the stage (`height = worldScreen.stage.height * inverseScaleFactor`, at y = 0) and lies right
/// above the map, "very low in z-order, so we're free to let it extend _below_ tile info and minimap": what covers its top
/// (the top bar and the status buttons) and its bottom (the tile info and the minimap) is scrolled past rather than cut off.
/// updateContent opens the table with an empty `topSpacerCell` of `coveredNotificationsTop` and closes it with an empty
/// `bottomSpacerCell` of `coveredNotificationsBottom` (`expandY`), which WorldScreen.update measures on every update and
/// updateSpacers resizes - "so we can scroll up or down far enough so the bottom or top entry is visible": any entry can be
/// brought into the band between them. The spacers are empty cells, so a touch on them reaches the map.
///
/// A SwiftUI ScrollView cannot be told this. It is a UIScrollView that takes every touch in its frame - a hit test anywhere
/// in it answers with SwiftUI's PlatformGroupContainer, and `contentShape`, on the ScrollView or on its content, does not
/// change that - so a list as wide as its widest entry swallowed the taps and drags left of the shorter ones. This pane is a
/// UIScrollView whose `point(inside:)` holds only the areas its entries and headers report (`notificationTouchArea()`), so
/// UIKit's hit test passes it by everywhere else - the spacers included - and finds the map's SKView beneath. On an entry
/// the touch goes to the hosted SwiftUI rows (their tap) and to this scroll view's pan, which scrolls on a drag and then
/// cancels the tap, as Scene2D's ScrollPane cancels its children's touch focus once it flicks.
///
/// The SKView must be what the hit test finds next, so the pane is not a UIViewRepresentable of its own but a UIKit sibling
/// right above the SKView in WorldMapView's container. SwiftUI puts every representable in a host view of its own, and on
/// iOS 17 that host (PlatformViewHost) keeps UIView's own hit test: a point inside its frame that none of its subviews takes
/// is the host's, so a point the pane turned down stayed with the pane's host and the whole column - the pane's width, the
/// stage's height - was dead to the map. (On iOS 26 the host, UIKitPlatformViewHost, asks the view it holds and lets a point
/// that view turns down through to what lies beneath.) In the container a point the pane turns down is the SKView's whatever
/// the host does, and the map's gesture recognizers, which are the SKView's, never see a touch on the pane.
///
/// Scene2D hits the actors added after the pane first - the top bar, the status buttons, the tile info and the minimap lie
/// over it and take the touches where they are - and a Popup covers the whole stage. UIKit's hit test does not always see
/// SwiftUI's drawing order: on iOS 26 it walks the platform views alone, and asked on the next-turn button or the minimap it
/// answered with the entry scrolled under them. So the pane is told what lies over it (`covers`, reported by those views
/// with `coversNotifications`) and takes no touch there, nor any while a popup is up (`touchable`), and those touches go
/// where they went before the pane reached under them.
struct NotificationsScrollPane<Content: View> {
    /// The rows' own size, which GameView measures on them: the hosted rows are laid out at it
    let contentSize: CGSize
    /// Unciv WorldScreen.update's `coveredNotificationsTop` (`stage.height - statusButtons.y`): the height of the pane's top
    /// that the top bar and the status buttons lie over - the topSpacerCell above the entries
    let coveredTop: CGFloat
    /// Unciv WorldScreen.update's `coveredNotificationsBottom` (`bottomTileInfoTable.height + bottomTileInfoTable.y`): the
    /// height of the pane's bottom that the tile info and the minimap lie over - the bottomSpacerCell below the entries
    let coveredBottom: CGFloat
    /// The notification to scroll into view on this update (NotificationsScroll.selectedCell): one tapped, or shown once more
    let reveal: NotificationReveal?
    /// The frames of the views that lie over the pane, in the pane's own coordinates (its top left corner on screen)
    let covers: [CGRect]
    /// False while the list is hidden or toggled off, or a popup covers the world screen
    let touchable: Bool
    /// The pane's frame in WorldMapView's coordinates: as wide as its widest entry, the stage's height at its right edge
    /// (NotificationsScroll.updateLayout, `setPosition(stage.width - width * scaleFactor, 0f)`)
    let frame: CGRect
    /// False while the list is hidden or the UI toggled off: Unciv's pane scrolled out of sight (Hidden, which keeps its
    /// scrollY), not visible (Disabled) or hidden with the rest of the UI (toggleUI)
    let shown: Bool
    /// Unciv startNewScreenJob: the next turn's WorldScreen has a NotificationsScroll of its own, at its top
    let worldScreen: Int
    let content: Content

    init(contentSize: CGSize, coveredTop: CGFloat, coveredBottom: CGFloat, reveal: NotificationReveal?, covers: [CGRect], touchable: Bool,
         frame: CGRect, shown: Bool, worldScreen: Int, @ViewBuilder content: () -> Content) {
        self.contentSize = contentSize
        self.coveredTop = coveredTop
        self.coveredBottom = coveredBottom
        self.reveal = reveal
        self.covers = covers
        self.touchable = touchable
        self.frame = frame
        self.shown = shown
        self.worldScreen = worldScreen
        self.content = content()
    }

    /// The pane of the world screen being shown and the hosting controller of its rows, kept across SwiftUI's updates
    final class Holder {
        var scroll: NotificationsUIScrollView?
        var host: UIHostingController<AnyView>?
        var worldScreen: Int?
    }

    /// A pane for a new world screen, at its top: the old one goes with its scroll position
    private func makePane(in container: WorldMapUIView, _ holder: Holder) {
        let scroll = NotificationsUIScrollView()
        scroll.backgroundColor = .clear
        scroll.showsVerticalScrollIndicator = false   // as the ScrollView it replaced (`showsIndicators: false`)
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        // Unciv `setOverscroll(false, true)`: overscroll vertically, never sideways - once the content is higher than the pane
        // (ScrollPane.layout: `scrollY = widgetHeight > areaHeight`), which is when a UIScrollView bounces without always
        scroll.alwaysBounceVertical = false
        scroll.alwaysBounceHorizontal = false
        scroll.scrollsToTop = false
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.view.backgroundColor = .clear
        // the pane runs along the screen's edge on a canvas that ignores the safe area; the rows must not be inset from it
        host.safeAreaRegions = []
        scroll.addSubview(host.view)
        scroll.rows = host.view
        // a pane made for a new world screen does not scroll to what was selected on the one before
        scroll.revealSerial = reveal?.serial ?? -1
        container.notifications = scroll
        holder.scroll = scroll
        holder.host = host
        holder.worldScreen = worldScreen
    }

    /// SwiftUI puts a representable's host view on the display's pixel grid, its edges rounded to the nearest pixel; the
    /// pane, placed by hand, is rounded the same way, so its rows are drawn where and as sharp as they were
    private static func pixelAligned(_ r: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return r }
        func round(_ v: CGFloat) -> CGFloat { (v * scale).rounded(.toNearestOrAwayFromZero) / scale }
        let minX = round(r.minX), minY = round(r.minY)
        return CGRect(x: minX, y: minY, width: max(0, round(r.maxX) - minX), height: max(0, round(r.maxY) - minY))
    }

    func update(in container: WorldMapUIView, _ holder: Holder, environment env: EnvironmentValues) {
        if holder.worldScreen != worldScreen || holder.scroll == nil { makePane(in: container, holder) }
        guard let scroll = holder.scroll, let host = holder.host else { return }
        // the frame first: the offset is clamped and a selection revealed against the pane's height
        let frame = Self.pixelAligned(frame, scale: env.displayScale)
        if scroll.frame != frame { scroll.frame = frame }
        scroll.alpha = shown ? 1 : 0
        host.rootView = AnyView(
            content
                // the hosted rows fill the host view from its top right, as the pane's notificationsTable is `right()`
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .coordinateSpace(.named(notificationsContentSpace))
                .onPreferenceChange(NotificationTouchAreasKey.self) { [weak scroll] areas in
                    scroll?.touchAreas.areas = areas
                    scroll?.revealIfNeeded()   // an entry enlarged on its tap is laid out again
                }
                // a hosting controller of its own does not inherit the canvas' environment
                .environment(\.stageWidth, env.stageWidth)
                .environment(\.onVirtualCanvas, env.onVirtualCanvas)
        )
        scroll.coveredTop = coveredTop
        scroll.coveredBottom = coveredBottom
        scroll.covers = covers
        scroll.touchable = touchable
        // updateSpacers: the entries sit under the top spacer and above the bottom one - the rows' host view below
        // coveredTop, and the content as high as the three together (vertical only, as the ScrollView(.vertical) it replaced:
        // a width that differs from the frame's by a rounding must not open a sideways scroll)
        let rows = CGRect(x: 0, y: coveredTop, width: contentSize.width, height: contentSize.height)
        if host.view.frame != rows { host.view.frame = rows }
        let height = coveredTop + contentSize.height + coveredBottom
        if scroll.contentSize.height != height { scroll.contentSize = CGSize(width: 0, height: height) }
        scroll.clampOffset()
        if let reveal, reveal.serial != scroll.revealSerial {
            scroll.revealSerial = reveal.serial
            scroll.pendingReveal = (reveal.id, CACurrentMediaTime() + NotificationsUIScrollView.revealWindow, scroll.contentOffset.y)
        }
        scroll.revealIfNeeded()
    }
}

/// Unciv WorldScreen's stage from the bottom up: the WorldMapHolder, then `stage.addActor(notificationsScroll) // very low
/// in z-order`, then everything else the world screen shows. GameView puts this view at the bottom of its ZStack: the map's
/// SKView (what SpriteView showed) and the notification pane right above it, UIKit siblings in one container under all of
/// SwiftUI's views - so a point the pane turns down is the map's (NotificationsScrollPane).
struct WorldMapView<Rows: View>: UIViewRepresentable {
    let scene: SKScene
    let notifications: NotificationsScrollPane<Rows>

    func makeCoordinator() -> NotificationsScrollPane<Rows>.Holder { .init() }

    func makeUIView(context: Context) -> WorldMapUIView {
        let view = WorldMapUIView()
        view.map.preferredFramesPerSecond = 60   // SpriteView(scene:preferredFramesPerSecond: 60)
        view.map.presentScene(scene)
        return view
    }

    func updateUIView(_ view: WorldMapUIView, context: Context) {
        if view.map.scene !== scene { view.map.presentScene(scene) }
        // SpriteView with its default options (no .ignoresSiblingOrder) sets this on the view it presents the scene in, after
        // MapScene.didMove turned it on: the map has always been drawn in sibling order
        view.map.ignoresSiblingOrder = false
        notifications.update(in: view, context.coordinator, environment: context.environment)
    }
}

/// WorldMapView's container: the SKView filling it and the notification pane over it. It never takes a touch itself - a
/// point is the pane's where an entry or a category header is, the map's everywhere else.
final class WorldMapUIView: UIView {
    let map = SKView()
    var notifications: NotificationsUIScrollView? {
        didSet {
            guard notifications !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let notifications { insertSubview(notifications, aboveSubview: map) }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        map.frame = bounds
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(map)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// A request to bring the entry `id` (NotificationItem.id) into the band between the status buttons and the tile info: a new
/// `serial` for every tap or one-time notification, so the same entry can be asked for again - counted on across world
/// screens (GameController.notificationReveal), as a pane made for a new one takes the serial it finds as seen
struct NotificationReveal: Equatable {
    let id: Int
    let serial: Int
}

/// The scroll view under NotificationsScrollPane: it answers a hit only where an entry or a category header is
/// (Unciv's `Touchable.childrenOnly` pane), and lets every other point through to the view beneath - the map.
final class NotificationsUIScrollView: UIScrollView {
    /// The entries' and headers' touch areas in the rows' coordinates (the host view's)
    let touchAreas = NotificationTouchAreas()
    /// The hosted rows, placed below the top spacer
    weak var rows: UIView?
    var coveredTop: CGFloat = 0 { didSet { if coveredTop != oldValue { setNeedsLayout() } } }
    var coveredBottom: CGFloat = 0 { didSet { if coveredBottom != oldValue { setNeedsLayout() } } }
    /// What lies over the pane, in its visible coordinates (bounds less the scroll offset)
    var covers: [CGRect] = []
    var touchable = true
    /// NotificationsScroll.update's selectedCell and the time it is good for: Unciv scrolls the selected entry into view in
    /// the update that follows its click (`GUI.setUpdateWorldOnNextRender()`), with the tile info that click selected
    /// already measured. Ours arrives over a few SwiftUI passes - the entry enlarged, the tile info shown, the spacers
    /// measured - so the request is checked on each of them for a moment, and dropped as soon as the player drags. Each
    /// pass decides from the offset the request found (update's previousScrollY), so the last one - the entry at its
    /// highlighted size - decides as Unciv's single update does.
    var pendingReveal: (id: Int, until: CFTimeInterval, from: CGFloat)? = nil
    var revealSerial = -1
    static let revealWindow: CFTimeInterval = 0.5
    private var laidOutSize: CGSize = .zero

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // `bounds.contains`: an entry scrolled out of sight is still laid out above or below the visible part of the pane,
        // and a touch outside the pane must not find it there
        guard touchable, bounds.contains(point), let rows else { return false }
        let visible = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
        if covers.contains(where: { $0.contains(visible) }) { return false }
        let p = CGPoint(x: point.x - rows.frame.minX, y: point.y - rows.frame.minY)
        return touchAreas.areas.contains { $0.rect.contains(p) }
    }

    /// Ours, for a clear screen: Unciv's entries slide on under its opaque status buttons and minimap, which hide them
    /// there; our top bar and status column let the map show through, so an entry is drawn only in the band between them -
    /// where alone it takes a touch anyway. The mask moves with the bounds, which scrolling moves.
    private let bandMask = CALayer()
    private func updateBandMask() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bandMask.backgroundColor = UIColor.black.cgColor
        bandMask.frame = CGRect(x: bounds.minX, y: bounds.minY + coveredTop, width: bounds.width, height: max(0, bounds.height - coveredTop - coveredBottom))
        if layer.mask !== bandMask { layer.mask = bandMask }
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateBandMask()
        // the pane's own height changed (the screen turned, the canvas was rescaled): the offset must still fit, and a
        // selection being revealed is measured against the new band
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        clampOffset()
        revealIfNeeded()
    }

    private var maxOffset: CGFloat { max(0, contentSize.height - bounds.height) }

    /// Unciv `scrollY = previousScrollY` through ScrollPane.setScrollY's clamp: the offset stays while the content changes,
    /// and shrunken content (a category collapsed, a notification gone, the tile info grown) pulls it back inside - a
    /// UIScrollView would leave it past the end until the next drag. Not while the player's finger or a bounce moves it.
    func clampOffset() {
        guard !isTracking, !isDecelerating, contentOffset.y > maxOffset else { return }
        contentOffset.y = maxOffset
    }

    /// NotificationsScroll.update with a selectedCell: `fullyVisible` - the entry between coveredNotificationsBottom and
    /// `stage.height - coveredNotificationsTop` - keeps the scroll, otherwise `centeredBottom` puts its middle in the middle
    /// of that band (ScrollPane clamps the result).
    func revealIfNeeded() {
        guard let p = pendingReveal else { return }
        guard CACurrentMediaTime() <= p.until, !isTracking else { pendingReveal = nil; return }
        guard let rows, let area = touchAreas.areas.first(where: { $0.entry == p.id }) else { return }
        let top = rows.frame.minY + area.rect.minY, bottom = rows.frame.minY + area.rect.maxY
        let bandTop = coveredTop, bandBottom = bounds.height - coveredBottom
        let y = min(max(0, p.from), maxOffset)
        let centered = (top + bottom) / 2 - (bandTop + bandBottom) / 2
        let target = top - y >= bandTop && bottom - y <= bandBottom ? y : min(max(0, centered), maxOffset)
        if contentOffset.y != target { setContentOffset(CGPoint(x: contentOffset.x, y: target), animated: false) }
    }
}

/// An entry's or a category header's touch area in the rows' coordinates, with the entry's id (NotificationItem.id) for an
/// entry and none for a header or the hide button
struct NotificationTouchArea: Equatable {
    let rect: CGRect
    let entry: Int?
}

/// Where the hosted rows' touch areas land: written by their preference, read by the scroll view's hit test
final class NotificationTouchAreas {
    var areas: [NotificationTouchArea] = []
}

/// The rows' coordinate space inside NotificationsScrollPane, the host view's own
private let notificationsContentSpace = "NotificationsScrollPane.content"

/// The notification entries' and category headers' touch areas in the coordinate space of the rows they are in, which
/// NotificationsScrollPane collects for its hit test and for scrolling an entry into view.
struct NotificationTouchAreasKey: PreferenceKey {
    static let defaultValue: [NotificationTouchArea] = []
    static func reduce(value: inout [NotificationTouchArea], nextValue: () -> [NotificationTouchArea]) { value += nextValue() }
}

extension View {
    /// Unciv NotificationsScroll: a ListItem or CategoryHeader, `Touchable.enabled` in a `Touchable.childrenOnly` pane - this
    /// view's frame, padding and all, is one of the areas NotificationsScrollPane takes a touch in. `entry` names the
    /// notification a ListItem shows, so the pane can scroll it into view.
    func notificationTouchArea(entry: Int? = nil) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: NotificationTouchAreasKey.self,
                                   value: [NotificationTouchArea(rect: g.frame(in: .named(notificationsContentSpace)), entry: entry)])
        })
    }
}

/// The frames of the world screen's views that lie over the notification pane (Unciv's actors added after it), in the
/// coordinate space GameView measures the pane in
struct NotificationsCoverKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

/// The frames of the views in the world screen's bottom right corner - the tile info, the minimap and its buttons - whose
/// top edge the pane's bottom spacer reaches up to where they run across it (Unciv's coveredNotificationsBottom)
struct NotificationsBottomCoverKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
    /// This view lies over the notification pane: the pane takes no touch in its frame (NotificationsScrollPane.covers)
    func coversNotifications(in space: String) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: NotificationsCoverKey.self, value: [g.frame(in: .named(space))]) })
    }
    /// This view lies over the notification pane's bottom (coversNotifications), and the pane's bottom spacer reaches up to
    /// its top where it runs across the pane (coveredNotificationsBottom)
    func coversNotificationsBottom(in space: String) -> some View {
        background(GeometryReader { g in
            let frame = g.frame(in: .named(space))
            Color.clear.preference(key: NotificationsCoverKey.self, value: [frame]).preference(key: NotificationsBottomCoverKey.self, value: [frame])
        })
    }
}
