// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Mirror of Unciv `ui/popups/UnitUpgradeMenu.kt`: what an upgrade costs, what the unit gains and loses, and the
/// two buttons - "Upgrade" and "Upgrade all [n] [unit] ([cost] gold)".
/// Unciv opens this menu even when the upgrade cannot be paid for or performed (`enable = false`): the benefits stay
/// on screen and only the buttons are disabled. Nothing here spends gold until a button is pressed.
struct UnitUpgradeMenuView: View {
    @ObservedObject var controller: GameController
    let unit: Unit
    /// The world screen closes through `controller.showUpgradeMenu`; the overview keeps its own presentation.
    var onClose: (() -> Void)? = nil
    @State private var shown = false   // Unciv UnitUpgradeMenu is an AnimatedMenuPopup: 0.33s fade and scale

    var body: some View {
        let s = controller.state
        // Unciv UnitUpgradeMenu shows one block per upgrade action, and the overview passes getUpgradeActionAnywhere.
        let targets = Self.upgradeTargets(s, unit)
        let all = s.allUpgradableUnits(like: unit)
        ZStack {
            Color.black.opacity(shown ? 0.35 : 0).ignoresSafeArea().bleedIntoCutout().onTapGesture { guard !UserSettings.neverCloseByTapOutside else { return }; close() }
            Panel(highlighted: true) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(targets) { target in choiceBlock(s, target, all) }
                        Button(L("Close")) { close() }.buttonStyle(ThemedButtonStyle(compact: true))
                            .keyboardShortcut(.escape, modifiers: [])   // AnimatedMenuPopup: keyShortcuts.add(KeyCharAndCode.BACK) { close() }
                    }
                }
            }.frame(maxWidth: 440, maxHeight: 520)
            .scaleEffect(shown ? 1 : 0.01).opacity(shown ? 1 : 0)
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.33)) { shown = true } }
    }

    /// One upgrade: Unciv's scrollable content (title + differences) over its fixed content (the buttons).
    @ViewBuilder
    private func choiceBlock(_ s: GameState, _ target: UnitDef, _ all: [Unit]) -> some View {
        let cost = s.upgradeCost(unit, to: target)
        let newResources = Self.newResourceRequirements(s, unit, to: target)
        let resourceText = newResources.sorted { $0.key < $1.key }.map { "\($0.value) \(L($0.key))" }.joined(separator: ", ")
        // Unciv UnitActionsUpgrade builds the title with the gold cost and, when the new unit eats a resource the
        // old one did not, that requirement too.
        let title = resourceText.isEmpty ? L("Upgrade to [\(target.name)] ([\(cost)] gold)")
                                         : L("Upgrade to [\(target.name)]\n([\(cost)] gold, [\(resourceText)])")
        let canAct = controller.isMyTurn && Self.canPerform(s, unit, to: target)
        VStack(alignment: .leading, spacing: 6) {
            // Unciv BaseUnitDescriptions.getUpgradeInfoTable: the title carries the target unit's icon.
            HStack(spacing: 6) {
                ArtIcon(name: target.name, folder: "Units", fallback: "arrow.up.circle.fill", size: 30)
                Text(title).font(Theme.heading(15)).foregroundStyle(Theme.gold).fixedSize(horizontal: false, vertical: true)
            }
            differences(s, target)
            // Unciv disables this button rather than hiding it, so the player can look before they can pay.
            // Unciv doUpgrade: `SoundPlayer.play(unitAction.uncivSound)`, then the action
            Button(L("Upgrade")) { perform { Audio.shared.play("upgrade"); controller.upgradeUnit(unit.id, to: target) } }
                .buttonStyle(ThemedButtonStyle(filled: true, compact: true)).disabled(!canAct)
                // Unciv getButton("Upgrade", KeyboardBinding.Upgrade) - one menu per upgrade there, so only a lone one takes the key here
                .modifier(BindingShortcut(name: Self.upgradeTargets(s, unit).count == 1 ? "Upgrade" : nil))
            // Unciv UnitUpgradeMenu.createFixedContent: "Upgrade all" appears only with more than one candidate,
            // and its cost and resource need are the single upgrade multiplied by that count.
            if all.count > 1, s.upgradeTarget(unit)?.name == target.name {
                let allCost = cost * all.count
                let allMissing = Self.insufficientResourcesMessage(s, unit, newResources.mapValues { $0 * all.count })
                let insufficientGold = (s.civ(unit.civId)?.gold ?? 0) < Double(allCost)
                Button(L("Upgrade all [\(all.count)] [\(unit.name)] ([\(allCost)] gold)")) { perform { Audio.shared.playRepeated("upgrade", count: 2); controller.upgradeAllLike(unit.id) } }   // doAllUpgrade: playRepeated (count = 2), then each unit's action
                    .buttonStyle(ThemedButtonStyle(compact: true))
                    .disabled(!controller.isMyTurn || insufficientGold || !allMissing.isEmpty)
                    .modifier(BindingShortcut(name: "Upgrade All"))   // getButton(upgradeAllText, KeyboardBinding.UpgradeAll)
                if !allMissing.isEmpty {
                    Text(allMissing).font(Theme.caption).foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
                }
            }
            Divider2()
        }
    }

    /// Unciv BaseUnitDescriptions.getUpgradeInfoTable: under the title, getDifferences' lines in their order - the cost
    /// and the abilities hidden to users left out; a resource no longer needed and a new free promotion carry their icon (link).
    @ViewBuilder
    private func differences(_ s: GameState, _ target: UnitDef) -> some View {
        let lines = ObjectDescriptions.unitDifferenceLines(unit.def, target, rs: s.rs)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                HStack(alignment: .top, spacing: 4) {
                    if let icon = l.icon { ArtIcon(name: icon.name, folder: icon.folder, fallback: "star", size: 14) }
                    Text(l.text).font(Theme.small).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.33)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.33) { if let onClose = onClose { onClose() } else { controller.showUpgradeMenu = false } }
    }

    /// Unciv UnitUpgradeMenu doUpgrade / doAllUpgrade: the menu's own unit, whichever unit the map has selected
    private func perform(_ action: () -> Void) {
        action()
        close()
    }
}

extension UnitUpgradeMenuView {
    /// Unciv UnitActionsUpgrade.getUpgradeActionAnywhere: every upgrade this unit may take, wherever it stands.
    /// Listed with `ignoreResources` exactly like Unciv, so a missing resource disables the button instead of
    /// hiding what the upgrade would give.
    static func upgradeTargets(_ s: GameState, _ unit: Unit) -> [UnitDef] {
        s.upgradeOptions(unit).filter { s.unitCanUpgrade(unit, to: $0, ignoreResources: true) }
    }

    /// Unciv UnitActionsUpgrade: whether the upgrade action exists (`action != null`) - inside our borders, with
    /// movement left, not embarked, resource requirements met, and the gold in the bank.
    static func canPerform(_ s: GameState, _ unit: Unit, to target: UnitDef) -> Bool {
        guard let tile = s.map[unit.coord], tile.ownerCivId == unit.civId, unit.hasMovement, !s.isEmbarked(unit),
              s.unitCanUpgrade(unit, to: target) else { return false }
        return (s.civ(unit.civId)?.gold ?? 0) >= Double(s.upgradeCost(unit, to: target))
    }

    /// Unciv UnitActionsUpgrade `resourceRequirementsDelta`: what the new unit consumes beyond the old one,
    /// negative entries dropped.
    static func newResourceRequirements(_ s: GameState, _ unit: Unit, to target: UnitDef) -> [String: Int] {
        let ctx = GameState.UniqueContext(civId: unit.civId, unit: unit)
        var delta: [String: Int] = [:]
        for (r, n) in s.resourceRequirementsPerTurn(requiredResource: unit.def.requiredResource, uniques: unit.def.uniqueObjects, ctx: ctx) { delta[r, default: 0] -= n }
        for (r, n) in s.resourceRequirementsPerTurn(requiredResource: target.requiredResource, uniques: target.uniqueObjects, ctx: ctx) { delta[r, default: 0] += n }
        return delta.filter { $0.value > 0 }
    }

    /// Unciv UnitUpgradeMenu.getInsufficientResourcesMessage: "Need [n] more [resource]" per resource short.
    static func insufficientResourcesMessage(_ s: GameState, _ unit: Unit, _ required: [String: Int]) -> String {
        guard !required.isEmpty else { return "" }
        let available = s.resourceCounts(unit.civId)
        var parts: [String] = []
        for (name, amount) in required.sorted(by: { $0.key < $1.key }) {
            let difference = amount - (available[name] ?? 0)
            if difference <= 0 { continue }
            parts.append(L("Need [\(difference)] more [\(name)]"))
        }
        return parts.joined(separator: "\n")
    }
}
