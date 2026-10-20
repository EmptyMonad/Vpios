// Shell for the Unciv 4X core (MPL-2.0): the UI kit the published core calls but leaves out (theme, panels, rows,
// sheets, the virtual canvas) and the app-flow hooks. Written fresh here: a plain dark Unciv-like look, no Unciv 4X art.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UIKit

// MARK: - Theme

enum Theme {
    // colours
    static let gold = Color(red: 0.93, green: 0.78, blue: 0.40)
    static let goldDim = Color(red: 0.70, green: 0.58, blue: 0.30)
    static let accent = Color(red: 0.36, green: 0.62, blue: 0.93)
    static let cream = Color(red: 0.95, green: 0.92, blue: 0.85)
    static let creamDim = Color(red: 0.72, green: 0.70, blue: 0.64)
    static let danger = Color(red: 0.90, green: 0.32, blue: 0.28)
    static let good = Color(red: 0.42, green: 0.80, blue: 0.42)
    static let background = Color(red: 0.07, green: 0.09, blue: 0.13)
    static let bg = background
    static let panel = Color(red: 0.13, green: 0.16, blue: 0.22)
    static let panelDark = Color(red: 0.10, green: 0.12, blue: 0.17)
    static let panelLight = Color(red: 0.20, green: 0.24, blue: 0.32)
    static let hairline = Color.white.opacity(0.12)
    static let fill = Color.white.opacity(0.08)
    static let fillStrong = Color.white.opacity(0.16)

    /// corner radii
    enum R {
        static let control: CGFloat = 8
        static let row: CGFloat = 6
        static let chip: CGFloat = 5
        static let card: CGFloat = 12
    }

    /// Unciv ScreenSize: the virtual canvas the UI is laid out on, by its short side.
    enum ScreenSize: String, CaseIterable {
        case tiny = "Tiny", small = "Small", medium = "Medium", large = "Large", huge = "Huge"
        var referenceHeight: CGFloat {
            switch self { case .tiny: 500; case .small: 600; case .medium: 700; case .large: 800; case .huge: 1000 }
        }
    }

    static var fontFamily: String = UserDefaults.standard.string(forKey: "epochs.fontFamily") ?? ""
    /// points per virtual-canvas unit
    private(set) static var uiScale: CGFloat = 1
    private(set) static var canvasWidth: CGFloat = 900

    static var screenShortSide: CGFloat {
        let b = UIScreen.main.bounds
        return min(b.width, b.height)
    }

    static func recomputeScale() {
        let size = ScreenSize(rawValue: UserSettings.screenSize) ?? .small
        let b = UIScreen.main.bounds
        let shortSide = min(b.width, b.height), longSide = max(b.width, b.height)
        uiScale = max(0.5, shortSide / size.referenceHeight)
        canvasWidth = longSide / uiScale
    }

    private static var multiplier: CGFloat { CGFloat(UserSettings.fontSizeMultiplier) }
    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let s = size * multiplier
        return fontFamily.isEmpty ? .system(size: s, weight: weight) : .custom(fontFamily, size: s).weight(weight)
    }
    static func heading(_ size: CGFloat) -> Font { font(size, weight: .semibold) }
    static func title(_ size: CGFloat) -> Font { font(size, weight: .bold) }
    static var small: Font { font(11) }
    static var caption: Font { font(12) }
    static var body: Font { font(14) }
}

// MARK: - environment: the virtual canvas

private struct OnVirtualCanvasKey: EnvironmentKey { static let defaultValue = false }
private struct StageWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct CutoutBleedKey: EnvironmentKey { static let defaultValue = EdgeInsets() }

extension EnvironmentValues {
    var onVirtualCanvas: Bool { get { self[OnVirtualCanvasKey.self] } set { self[OnVirtualCanvasKey.self] = newValue } }
    var stageWidth: CGFloat { get { self[StageWidthKey.self] } set { self[StageWidthKey.self] = newValue } }
    var cutoutBleed: EdgeInsets { get { self[CutoutBleedKey.self] } set { self[CutoutBleedKey.self] = newValue } }
}

/// Unciv's stage: the content is laid out on a virtual canvas of the chosen ScreenSize and scaled to the screen.
struct VirtualCanvas<Content: View>: View {
    @ViewBuilder var content: () -> Content
    init(@ViewBuilder _ content: @escaping () -> Content) { self.content = content }
    var body: some View {
        GeometryReader { geo in
            let scale = Theme.uiScale
            let w = geo.size.width / scale, h = geo.size.height / scale
            content()
                .environment(\.onVirtualCanvas, true)
                .environment(\.stageWidth, w)
                .environment(\.cutoutBleed, geo.safeAreaInsets)
                .frame(width: w, height: h)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Let a background reach under the notch / home indicator.
    func bleedIntoCutout() -> some View { ignoresSafeArea() }

    /// Unciv long press (0.5 s): sets `fired` so the tap that ends the press is not also a tap.
    func uncivLongPress(fired: Binding<Bool>, perform action: @escaping () -> Void) -> some View {
        simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in fired.wrappedValue = true; action() })
    }

    /// A screen presented full-size on its own virtual canvas.
    func stageSheet<C: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View {
        fullScreenCover(isPresented: isPresented) { VirtualCanvas { content() } }
    }

    /// The store build's "coming soon" overlay on entry points it hasn't opened; everything is open here.
    func comingSoon(alignment: Alignment = .topTrailing, mods: Bool = false, place: String) -> some View { self }

    /// The store build's launch-argument test hooks; none here.
    func launchArgumentHooks(_ root: RootView) -> some View { self }

    /// A popup menu (Unciv's Popup with a list of buttons), as a sheet.
    func themedMenu<C: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View {
        sheet(isPresented: isPresented) {
            ScrollView { VStack(alignment: .leading, spacing: 2) { content() }.padding(12) }
                .background(Theme.background.ignoresSafeArea())
                .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - building blocks

struct Panel<Content: View>: View {
    var padding: CGFloat = 10
    var highlighted = false
    @ViewBuilder var content: () -> Content
    init(padding: CGFloat = 10, highlighted: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding; self.highlighted = highlighted; self.content = content
    }
    var body: some View {
        content()
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: Theme.R.card, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.R.card, style: .continuous)
                .stroke(highlighted ? Theme.gold : Theme.hairline, lineWidth: highlighted ? 1.5 : 1))
    }
}

struct ThemedButtonStyle: ButtonStyle {
    var filled = false
    var destructive = false
    var compact = false
    var multiline = false
    init(filled: Bool = false, destructive: Bool = false, compact: Bool = false, multiline: Bool = false) {
        self.filled = filled; self.destructive = destructive; self.compact = compact; self.multiline = multiline
    }
    func makeBody(configuration: Configuration) -> some View {
        let tint = destructive ? Theme.danger : Theme.gold
        configuration.label
            .lineLimit(multiline ? nil : 1)
            .multilineTextAlignment(.center)
            .font(compact ? Theme.caption.weight(.semibold) : Theme.body.weight(.semibold))
            .foregroundStyle(filled ? Theme.background : tint)
            .padding(.horizontal, compact ? 10 : 16).padding(.vertical, compact ? 5 : 9)
            .background(RoundedRectangle(cornerRadius: Theme.R.control, style: .continuous)
                .fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(Theme.fill)))
            .overlay(RoundedRectangle(cornerRadius: Theme.R.control, style: .continuous).stroke(tint.opacity(filled ? 0 : 0.6), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct Divider2: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

struct MenuDivider: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 4) }
}

struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(Theme.heading(13)).foregroundStyle(Theme.gold).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SoonBadge: View {
    var body: some View {
        Text("Soon").font(Theme.small.bold()).foregroundStyle(Theme.background)
            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Theme.goldDim))
    }
}

struct MenuRow: View {
    let title: String
    let systemImage: String
    var note: String? = nil
    let action: () -> Void
    init(title: String, systemImage: String, note: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.note = note; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).frame(width: 22).foregroundStyle(Theme.gold)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.body).foregroundStyle(Theme.cream)
                    if let note, !note.isEmpty { Text(note).font(Theme.small).foregroundStyle(Theme.creamDim) }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8).padding(.horizontal, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ThemedRow<Leading: View, Trailing: View>: View {
    let title: String
    let detail: String?
    let selected: Bool
    var onDoubleTap: (() -> Void)? = nil
    var onLongPress: (() -> Void)? = nil
    var titleColor: Color? = nil
    let action: () -> Void
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    @State private var longPressFired = false

    init(title: String, detail: String?, selected: Bool, onDoubleTap: (() -> Void)? = nil, onLongPress: (() -> Void)? = nil,
         titleColor: Color? = nil, action: @escaping () -> Void,
         @ViewBuilder leading: @escaping () -> Leading, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title; self.detail = detail; self.selected = selected; self.onDoubleTap = onDoubleTap
        self.onLongPress = onLongPress; self.titleColor = titleColor; self.action = action
        self.leading = leading; self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            leading()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body).foregroundStyle(titleColor ?? (selected ? Theme.gold : Theme.cream))
                if let detail, !detail.isEmpty { Text(detail).font(Theme.small).foregroundStyle(Theme.creamDim).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: Theme.R.row).fill(selected ? Theme.panelLight : Theme.panelDark))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let onDoubleTap { onDoubleTap() } else { action() } }
        .onTapGesture { if longPressFired { longPressFired = false } else { action() } }
        .onLongPressGesture(minimumDuration: 0.5) { if let onLongPress { longPressFired = true; onLongPress() } }
    }
}

extension ThemedRow where Trailing == EmptyView {
    init(title: String, detail: String?, selected: Bool, onDoubleTap: (() -> Void)? = nil, onLongPress: (() -> Void)? = nil,
         titleColor: Color? = nil, action: @escaping () -> Void, @ViewBuilder leading: @escaping () -> Leading) {
        self.init(title: title, detail: detail, selected: selected, onDoubleTap: onDoubleTap, onLongPress: onLongPress,
                  titleColor: titleColor, action: action, leading: leading, trailing: { EmptyView() })
    }
}

extension ThemedRow where Leading == EmptyView, Trailing == EmptyView {
    init(title: String, detail: String?, selected: Bool, onDoubleTap: (() -> Void)? = nil, onLongPress: (() -> Void)? = nil,
         titleColor: Color? = nil, action: @escaping () -> Void) {
        self.init(title: title, detail: detail, selected: selected, onDoubleTap: onDoubleTap, onLongPress: onLongPress,
                  titleColor: titleColor, action: action, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

struct ThemedSheet<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var scrolls = true
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content
    init(_ title: String, subtitle: String? = nil, scrolls: Bool = true, onClose: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.subtitle = subtitle; self.scrolls = scrolls; self.onClose = onClose; self.content = content
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.title(20)).foregroundStyle(Theme.gold)
                    if let subtitle, !subtitle.isEmpty { Text(subtitle).font(Theme.caption).foregroundStyle(Theme.creamDim) }
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.system(size: 24)).foregroundStyle(Theme.creamDim) }
                    .buttonStyle(.plain)
            }
            .padding(12)
            Divider2()
            if scrolls { ScrollView { content().padding(12) } } else { content() }
        }
        .background(Theme.background.ignoresSafeArea())
    }
}

struct ThemedDialog<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let onDismiss: () -> Void
    @ViewBuilder var content: () -> Content
    init(title: String, subtitle: String? = nil, onDismiss: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.subtitle = subtitle; self.onDismiss = onDismiss; self.content = content
    }
    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture(perform: onDismiss)
            Panel(padding: 16, highlighted: true) {
                VStack(spacing: 10) {
                    Text(title).font(Theme.heading(17)).foregroundStyle(Theme.gold)
                    if let subtitle, !subtitle.isEmpty { Text(subtitle).font(Theme.caption).foregroundStyle(Theme.creamDim) }
                    content()
                }
            }
            .frame(maxWidth: 520)
            .padding(24)
        }
    }
}

/// A nation's emblem: its icon (if the art has one) on its outer colour, in its inner colour.
struct NationBadge: View {
    let nation: NationDef?
    let size: CGFloat
    var body: some View {
        let outer = nation?.outerColor ?? [160, 32, 240]
        let inner = nation?.innerColor ?? [255, 255, 255]
        func c(_ v: [Int]) -> Color { v.count >= 3 ? Color(red: Double(v[0]) / 255, green: Double(v[1]) / 255, blue: Double(v[2]) / 255) : .purple }
        return ZStack {
            Circle().fill(c(outer))
            if let n = nation, let img = Art.shared.image(n.name, folder: "NationIcons") {
                Image(uiImage: img).renderingMode(.template).resizable().scaledToFit().foregroundStyle(c(inner)).padding(size * 0.18)
            } else {
                Text(String((nation?.name ?? "?").prefix(1))).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(c(inner))
            }
        }
        .frame(width: size, height: size)
    }
}

/// An icon from Unciv's art (folder/name), or an SF Symbol when the art has none.
struct ArtIcon: View {
    let name: String
    let folder: String
    let fallback: String
    let size: CGFloat
    var body: some View {
        Group {
            if let img = Art.shared.image(name, folder: folder) {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                Image(systemName: fallback).resizable().scaledToFit().foregroundStyle(Theme.creamDim)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - measurement (off)

enum UIMeasure {
    @discardableResult static func start() -> Double { 0 }
    static func stop(_ label: String, _ started: Double = 0) {}
    static func count(_ label: String) {}
}

// MARK: - app flow (the store build's own screens: none here)

struct AppFlowState {
    var showsOwnScreen = false
}

struct AppFlowHooks: ViewModifier {
    let root: RootView
    func body(content: Content) -> some View { content }
}

extension RootView {
    @ViewBuilder var appOwnScreen: some View { EmptyView() }
}

enum StoreBuild {
    static let onlineAndModsComingSoon = false
}

enum LaunchOptions {
    static var opensNewGameScreen: Bool { ProcessInfo.processInfo.arguments.contains("--new-game") }
}

enum SupportContact {
    static let pasteLine = "paste it into an issue on github.com/EmptyMonad/vpios)."
}

struct MainMenuBrandingHeader: View {
    let tablet: Bool
    let onAbout: () -> Void
    var body: some View {
        VStack(spacing: 4) {
            Text("Unciv").font(Theme.title(tablet ? 48 : 36)).foregroundStyle(Theme.gold)
            Text("Vox Populi build").font(Theme.caption).foregroundStyle(Theme.creamDim)
        }
        .onTapGesture(perform: onAbout)
    }
}

struct MainMenuBrandingFooter: View {
    let onAbout: () -> Void
    var body: some View {
        Button("About", action: onAbout).buttonStyle(ThemedButtonStyle(compact: true))
    }
}

struct AboutView: View {
    let onClose: () -> Void
    var body: some View {
        ThemedSheet("About", subtitle: nil, onClose: onClose) {
            VStack(alignment: .leading, spacing: 10) {
                Text("A personal build of the Unciv 4X core (MPL-2.0) by AiArt LTD, itself a Swift translation of Unciv by Yair Morgenstern and the Unciv contributors. Art and game data are Unciv's.")
                Text("Not affiliated with Unciv 4X, AiArt LTD or the Unciv project. Source: github.com/EmptyMonad/vpios")
            }
            .font(Theme.body).foregroundStyle(Theme.cream)
        }
    }
}

// MARK: - misc store-build pieces

/// The store build's analytics sink; nothing is sent here.
func observe(_ event: GameEvent) {}

extension L10n {
    /// The store build's own Turkish strings (its developer's additions); none here.
    static let turkish: [String: String] = [:]
}

extension OptionsView {
    /// The store build's analytics/privacy options; there is nothing to opt out of here.
    var privacySection: some View { EmptyView() }
}

extension UIColor {
    /// An Unciv RGB triple (0...255); fewer than three numbers is Color.PURPLE, as Nation.safeColorFromRGB.
    convenience init(rgb: [Int]) {
        let v = rgb.count >= 3 ? rgb : [160, 32, 240]
        self.init(red: CGFloat(v[0]) / 255, green: CGFloat(v[1]) / 255, blue: CGFloat(v[2]) / 255, alpha: 1)
    }
}
