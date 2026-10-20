// Shell for the Unciv 4X core (MPL-2.0): small pieces of the developer's harness that game logic and UI also call.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

@_exported import UniformTypeIdentifiers
import SwiftUI

/// Probe hook of the developer's harness ("heartbeat"); off.
func hbr<T>(_ label: String, _ value: T) {}

extension GameState {
    /// EVLOG list join
    static func evJoin(_ names: [String]) -> String { names.joined(separator: ",") }

    /// The names of one side's offers in Unciv's TradeOffersList order: getAvailableOffers' order (as recordOffers
    /// builds it - an embassy as "Accept Embassy", a city as its Unciv id), the names in `tail` moved to the end in that
    /// order (uncivOfferOrder). Game logic keeps `evTailGive` / `evTailWant` with it (TradeOffersList.add appends).
    func evOfferNames(_ side: TradeSide, other: TradeSide, tail: [String] = []) -> [String] {
        var out: [String] = []
        if side.embassy { out.append("Accept Embassy") }
        if side.peace { out.append("Peace Treaty") }
        if side.openBorders { out.append("Open Borders") }
        if side.researchAgreement { out.append("Research Agreement") }
        if side.defensivePact { out.append("Defensive Pact") }
        var seen = Set<String>()
        for r in side.resources where seen.insert(r).inserted { out.append(r) }
        for r in side.stockpiles.filter({ $0.value > 0 }).map(\.key).sorted() { out.append(r) }
        if side.gold > 0 { out.append("Gold") }
        if side.goldPerTurn > 0 { out.append("Gold per turn") }
        for c in side.cities { out.append(uncivCityId(c)) }
        for x in side.introductions { out.append(civ(x)?.nation ?? "?") }
        for w in side.warOns { out.append(civ(w)?.nation ?? "?") }
        for x in side.peaceWith { out.append(civ(x)?.nation ?? "?") }
        return uncivOfferOrder(out, name: { $0 }, tail: tail)
    }
}

/// Lays its content out no wider than `width` (Unciv Label.wrap with a fixed width).
struct WrapWidth<Content: View>: View {
    let width: CGFloat
    @ViewBuilder var content: () -> Content
    init(width: CGFloat, @ViewBuilder content: @escaping () -> Content) { self.width = width; self.content = content }
    var body: some View { content().frame(maxWidth: width) }
}

extension View {
    /// A full-screen screen on its own virtual canvas (Unciv's stage).
    func onStage() -> some View { VirtualCanvas { self } }
}
