// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv EasterEggFloatingArt: on a holiday, decorations drift across the main menu every few seconds (art from Unciv's EasterEggs tile set).
struct EasterEggFloatingArt: View {
    let holiday: HolidayDates.Holiday
    @State private var items: [Item] = []
    @State private var timer: Timer? = nil

    struct Item: Identifiable { let id = UUID(); let image: UIImage; var from: CGPoint; var to: CGPoint; let duration: Double; var moved = false }

    static func images(for holiday: HolidayDates.Holiday) -> [UIImage] {
        let names: [String]
        switch holiday {
        case .Easter, .Passover: names = (1...8).map { "Easter Egg \($0)" } + ["Giant Easter Egg"]
        case .Samhain, .DiaDeLosMuertos, .Friday13th: names = (1...5).map { "Halloween candy \($0)" } + ["Giant Pumpkin"]
        case .Xmas, .YuleGoat: names = (1...7).map { "Xmas decoration \($0)" } + ["Xmas Tree"]
        default: names = (1...8).map { "Easter Egg \($0)" }
        }
        return names.compactMap { Art.shared.image($0, folder: "EasterEggs") }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(items) { it in
                    Image(uiImage: it.image).resizable().scaledToFit().frame(width: 48, height: 48)
                        .position(it.moved ? it.to : it.from)
                        .animation(.easeInOut(duration: it.duration), value: it.moved)
                }
            }
            .onAppear { schedule(in: geo.size) }
            .onDisappear { timer?.invalidate(); timer = nil }
        }
    }

    /// nextImage: wait 2–6 s, pick an image and an angle, fly through the centre (±30°) over 3–11 s, then fade.
    private func schedule(in size: CGSize) {
        let images = EasterEggFloatingArt.images(for: holiday)
        guard !images.isEmpty else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 2...6), repeats: false) { _ in
            let cx = size.width / 2, cy = size.height / 2
            let radius = sqrt(cx * cx + cy * cy) + 48
            let angle = Double.random(in: 0..<(2 * .pi))
            let angle2 = angle + (Double.random(in: 0...1) * 0.3333 - 0.1667) * .pi
            var item = Item(image: images.randomElement()!, from: CGPoint(x: cx - radius * cos(angle), y: cy - radius * sin(angle)), to: CGPoint(x: cx + radius * cos(angle2), y: cy + radius * sin(angle2)), duration: Double.random(in: 3...11))
            items.append(item)
            DispatchQueue.main.async { if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].moved = true } }
            item.moved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + item.duration + 0.2) { items.removeAll { $0.id == item.id }; schedule(in: size) }
        }
    }
}
