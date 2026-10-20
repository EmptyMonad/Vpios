// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// MARK: - Social policies

struct PolicyScreen: View {
    @ObservedObject var controller: GameController
    @State private var confirmBranch: String? = nil
    @State private var selectedPolicy: String? = nil          // Unciv PolicyPickerScreen.selectedPolicyButton
    @State private var describedBranches: Set<String> = []    // Unciv BranchGroup.toggle: description instead of the grid
    var body: some View {
        let s = controller.state
        let civ = controller.selectedCiv   // Unciv PolicyPickerScreen(worldScreen.selectedCiv, worldScreen.canChangeState)
        let cost = s.policyCost(civ)
        let canChangeState = controller.isMyTurn && !controller.player.isSpectator
        // Unciv PolicyManager.allPoliciesAdopted: nothing left that could be adopted
        let allAdopted = !s.rs.policyBranches.contains { !civ.openBranches.contains($0.name) && (s.canOpenBranch(civ, $0) || s.rs.eraIndex(civ.eraName) < s.rs.eraIndex($0.era)) } && !s.rs.policies.values.contains { !civ.policies.contains($0.name) && s.canAdopt(civ, policy: $0) }
        let buttonText = allAdopted ? L("All policies adopted") : civ.freePolicies > 0 ? L("Adopt free policy") : L("Adopt policy") + "\n(\(Int(civ.cultureStored))/\(Int(cost)))"
        // PolicyPickerScreen shows no adopted / completed counts
        ThemedSheet(L("Social Policies"), subtitle: nil, onClose: { controller.showPolicies = false }) {
            // Unciv PickerScreen: the selected policy's description and the right-side button
            Panel(padding: 8, highlighted: true) {
                VStack(alignment: .leading, spacing: 4) {
                    if let name = selectedPolicy, let p = s.rs.policies[name] {
                        // Unciv PolicyPickerScreen.pickPolicy: descriptionLabel = policy.getDescription(), which opens the
                        // policy's Civilopedia page when activated
                        Button { controller.civilopediaEntry = "Policy/\(p.name)"; controller.showCivilopedia = true } label: {
                            Text(ObjectDescriptions.policyDescription(p, rs: s.rs)).font(Theme.small).foregroundStyle(Theme.cream).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        }.buttonStyle(.plain)
                    }
                    if !(selectedPolicy.map { civ.policies.contains($0) } ?? false) {
                        Button(buttonText) { confirmAction() }.buttonStyle(ThemedButtonStyle(filled: true, compact: true, multiline: true)).disabled(!isPickable(selectedPolicy, canChangeState: canChangeState))
                    }
                }
            }
            // Unciv PolicyPickerScreen(select): a branch named by the notification (PolicyAction) shows its description
            // (`branchToGroup[select]?.toggle()`), a policy is picked (pickPolicy)
            .onAppear {
                guard let sel = controller.policyHighlight else { return }
                controller.policyHighlight = nil
                if s.rs.policyBranches.contains(where: { $0.name == sel }) { describedBranches.insert(sel) }
                else if s.rs.policies[sel] != nil { selectedPolicy = sel }
            }
            ForEach(s.rs.policyBranches) { branch in
                let open = civ.openBranches.contains(branch.name)
                let complete = civ.policies.contains(branch.completion?.name ?? "-")
                let eraLocked = s.rs.eraIndex(branch.era) > s.rs.eraIndex(civ.eraName)
                let branchPickable = canChangeState && !open && s.canOpenBranch(civ, branch) && s.canAffordPolicy(civ)
                let amountToDo = branch.regularPolicies.count
                let amountDone = complete ? amountToDo : branch.regularPolicies.filter { civ.policies.contains($0.name) }.count
                Panel(highlighted: open && !complete) {
                    VStack(alignment: .leading, spacing: 8) {
                        // Unciv getBranchHeader: tapping toggles the description
                        Button { if describedBranches.contains(branch.name) { describedBranches.remove(branch.name) } else { describedBranches.insert(branch.name) } } label: {
                            HStack(spacing: 10) {
                                ArtIcon(name: branch.name, folder: "PolicyIcons", fallback: "star.fill", size: 30)
                                Text(L(branch.name)).font(Theme.heading(17)).foregroundStyle(complete ? Theme.gold : Theme.cream)
                                Spacer()
                                Image(systemName: describedBranches.contains(branch.name) ? "chevron.up" : "chevron.down").foregroundStyle(Theme.creamDim)
                            }
                        }.buttonStyle(.plain)
                        if describedBranches.contains(branch.name) {
                            VStack(alignment: .leading, spacing: 4) {
                                if eraLocked { Text(L("Unlocked at") + " " + L(branch.era)).font(Theme.small) }
                                // Unciv BranchGroup: "{On adoption}:" with branch.getDescription(), "{On completion}:" with
                                // branch.policies.last().getDescription() - "• " lines, no "Only available" or global alert
                                Text(L("On adoption") + ":").font(Theme.small.bold())
                                Text(ObjectDescriptions.policyDescription(name: branch.name, uniques: branch.uniqueObjects, isMember: false)).font(Theme.small).foregroundStyle(Theme.creamDim).fixedSize(horizontal: false, vertical: true)
                                if let done = branch.completion {
                                    Text(L("On completion") + ":").font(Theme.small.bold())
                                    Text(ObjectDescriptions.policyDescription(done, rs: s.rs)).font(Theme.small).foregroundStyle(Theme.creamDim).fixedSize(horizontal: false, vertical: true)
                                }
                                let onlyAvailable = branch.uniques.map(Unique.init).filter { $0.pattern == "Only available" }
                                if !onlyAvailable.isEmpty {
                                    Text(L("Only available") + ":").font(Theme.small.bold()).foregroundStyle(Theme.danger)
                                    ForEach(onlyAvailable.flatMap { $0.conditionals.map { $0.text } }, id: \.self) { Text("• " + L($0)).font(Theme.small).foregroundStyle(Theme.danger) }
                                }
                            }
                        } else {
                            // Unciv BranchGroup.toggle: the top button goes with the grid (`topBtnCell.clearActor()` while described)
                            // Unciv getTopButton: "Completed (done/total)", the era while locked, otherwise "Adopt"
                            Button { if branchPickable { confirmBranch = branch.name } } label: {
                                HStack {
                                    Text(open ? L("Completed") + " (\(amountDone)/\(amountToDo))" : eraLocked ? L(branch.era) : L("Adopt")).font(Theme.caption.bold())
                                    if !branchPickable && !open { Image(systemName: "lock.fill").font(.system(size: 11)) }
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                                .foregroundStyle(open ? Theme.gold : branchPickable ? Theme.cream : Theme.creamDim)
                                .background(GeometryReader { g in ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 6).fill(branchPickable ? Theme.panelLight : Theme.panelDark.opacity(0.8))
                                    if open && amountToDo > 0 { RoundedRectangle(cornerRadius: 6).fill(Theme.goldDim.opacity(0.6)).frame(width: g.size.width * CGFloat(amountDone) / CGFloat(amountToDo)) }
                                } })
                            }
                            .buttonStyle(.plain)
                            .confirmationDialog(L("Are you sure you want to adopt [\(branch.name)]?"), isPresented: Binding(get: { confirmBranch == branch.name }, set: { if !$0 { confirmBranch = nil } }), titleVisibility: .visible) {
                                Button(L("Adopt")) { controller.adopt(branch: branch.name) }
                                Button(L("Cancel"), role: .cancel) {}
                            }   // Unciv PolicyPickerScreen ConfirmPopup
                            PolicyTreeView(controller: controller, branch: branch, selectedPolicy: selectedPolicy, onSelect: { selectedPolicy = $0 }, onConfirm: { selectedPolicy = $0; confirmAction() })
                        }
                    }
                }
            }
        }
        .screenShown("policies")
    }
    /// Unciv Policy.isPickable(civ, canChangeState)
    private func isPickable(_ name: String?, canChangeState: Bool) -> Bool {
        let s = controller.state, civ = controller.selectedCiv
        guard canChangeState, let n = name, let p = s.rs.policies[n], !civ.policies.contains(n) else { return false }
        return s.canAdopt(civ, policy: p) && s.canAffordPolicy(civ)
    }
    /// Unciv PolicyPickerScreen.confirmAction
    private func confirmAction() {
        guard isPickable(selectedPolicy, canChangeState: controller.isMyTurn && !controller.state.player.isSpectator), let name = selectedPolicy else { return }
        controller.adopt(policy: name)
    }
}

/// Makes a raw unique readable: strips brackets and conditional angle brackets.
func pretty(_ unique: String) -> String {
    unique.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        .replacingOccurrences(of: "<", with: "(").replacingOccurrences(of: ">", with: ")")
}
/// Uniques that only steer the AI are noise for players.
func isPlayerFacing(_ unique: String) -> Bool {
    let p = Unique(unique).pattern
    // Unciv UniqueType.Comment ("Comment [comment]") has no HiddenToUsers flag: its bracketed text is listed.
    if p == "Will not be displayed in Civilopedia" { return false }
    // Unciv Unique.isHiddenToUsers: the UniqueFlag.HiddenToUsers types - the 47 of 4.22.1's UniqueType.kt, `flags =
    // UniqueFlag.setOfHiddenToUsers` and the two with setOfHiddenNoConditionals ("Mark tutorial [] complete", and "Suppress
    // warning []" by the test below) - and the <hidden from users> modifier. A text
    // no UniqueType of 4.22.1 has ("AI will sell at []", "Hidden when religion is disabled" ...) is an unknown unique, which
    // isHiddenToUsers lets through and uniquesToCivilopediaTextLines lists. The list had only the AI and audio ones, so
    // the map-generation uniques of terrains and resources ("Occurs on latitudes from [] to [] ...", "A Region is formed with at
    // least []% [] tiles ...", "Generated with weight []" ...), which no translation file carries, stood in English in the
    // Civilopedia of a Turkish game where Unciv shows nothing.
    let hiddenToUsers: Set<String> = [
        "Automation is a primary action", "Never appears as a Barbarian unit", "Must be adjacent to [] [] tiles",
        "Must be adjacent to [] to [] [] tiles", "Must not be on [] largest landmasses", "Must be on [] largest landmasses",
        "Occurs on latitudes from [] to [] percent of distance equator to pole", "Occurs in groups of [] to [] tiles",
        "Neighboring tiles will convert to []", "Always Fertility [] for Map Generation", "[] to Fertility for Map Generation",
        "A Region is formed with at least []% [] tiles, with priority []",
        "A Region is formed with at least []% [] tiles and [] tiles, with priority []", "A Region can not contain more [] tiles than [] tiles",
        "Base Terrain on this tile is not counted for Region determination", "Starts in regions of this type receive an extra []",
        "Never receives any resources", "Becomes [] when adjacent to []", "Considered [] when determining start locations",
        "Doesn't generate naturally", "Occurs at temperature between [] and [] and humidity between [] and []",
        "Occurs in chains at high elevations", "Occurs in groups around high elevations",
        "Every [] tiles with this terrain will receive a major deposit of a strategic resource.", "Excluded from map editor",
        "Not shown on world screen", "Generated with weight []", "Minor deposits generated with weight []",
        "Generated near City States with weight []", "Special placement during map generation", "Generated on every [] tiles",
        "AI will sell at [] Gold", "AI will buy at [] Gold", "Marks a barbarian camp", "[]% weight to [] for AI decisions",
        "if tutorials are enabled", "if tutorial [] is completed", "Play [] sound", "Get the leader title of []",
        "Choose a music track for [], [], []", "[]% weight to this choice for AI decisions", "with [] priority",
        "Will not be displayed in Civilopedia", "Shown while unbuilable", "Civilopedia link []", "Mark tutorial [] complete"
    ]
    if hiddenToUsers.contains(p) || p == "Suppress warning []" { return false }
    // a HiddenToUsers type as a modifier ("<Suppress warning [...]>", "<[x]% weight to this choice ...>") hides only itself:
    // getDisplayText leaves it out of the text (ObjectDescriptions.displayText) - only <hidden from users> hides the unique
    return !unique.contains("<hidden from users>")
}

/// isPlayerFacing under a name the types with their own isPlayerFacing can reach.
func uniqueIsPlayerFacing(_ unique: String) -> Bool { isPlayerFacing(unique) }

/// Unciv NotificationIcon.getImage: the folder a notification icon comes from, tried in Unciv's order.
/// An icon written as "Folder/Name" already says where it lives; Unciv passes those straight to ImageGetter.
func notificationIconFolder(_ icon: String, _ rs: Ruleset) -> String {
    if rs.techs[icon] != nil { return "TechIcons" }
    if rs.nations[icon] != nil { return "NationIcons" }
    if rs.units[icon] != nil { return "UnitIcons" }
    if rs.promotions[icon] != nil { return "PromotionIcons" }
    if rs.resources[icon] != nil { return "ResourceIcons" }
    // Unciv writes these two as a path; ours name them bare, so they are resolved here instead.
    if rs.buildings[icon] != nil { return "BuildingIcons" }
    if rs.improvements[icon] != nil { return "ImprovementIcons" }
    return "OtherIcons"
}

/// Unciv NotificationIcon sabitleri: orada her biri tam bir doku yoludur, bizde çıplak ad olarak
/// geçiriliyor. Birebir aynı dosyaya düşmek için Unciv'in kendi sabit tablosu.
/// A constant whose name is also a ruleset object's - Construction (a technology), Barbarians (a nation), Scout (a
/// unit) - is passed as its path ("StatIcons/Production", "ImprovementIcons/Barbarian encampment", "UnitIcons/Scout"):
/// the bare name resolves to the ruleset object first, as Unciv's getImage resolves a bare name.
let uncivNotificationIconPaths: [String: String] = [
    "Barbarians": "ImprovementIcons/Barbarian encampment",
    "City": "ImprovementIcons/City center",
    "CityState": "OtherIcons/CityState",
    "Crosshair": "OtherIcons/CrosshairB",
    "Culture": "StatIcons/Culture",
    "Construction": "StatIcons/Production",
    "Death": "OtherIcons/DisbandUnit",
    "Diplomacy": "OtherIcons/Diplomacy",
    "Faith": "StatIcons/Faith",
    "Food": "StatIcons/Food",
    "Gold": "StatIcons/Gold",
    "Growth": "StatIcons/Population",
    "Happiness": "StatIcons/Happiness",
    "Population": "StatIcons/Population",
    "Production": "StatIcons/Production",
    "Question": "OtherIcons/Question",
    "Ruins": "ImprovementIcons/Ancient ruins",
    "Science": "StatIcons/Science",
    "Scout": "UnitIcons/Scout",
    "Spy": "OtherIcons/Spy",
    "Trade": "StatIcons/Acquire",
    "War": "OtherIcons/Pillage",
    "Quest": "OtherIcons/Quest",
]

/// The string Unciv itself stores for a notification icon: a constant's texture path, a building or an improvement
/// behind its folder, anything else (a nation, a unit, a tech, a resource, a promotion, a path) as it is.
func uncivNotificationIconString(_ icon: String) -> String {
    if icon.contains("/") { return icon }
    let rs = Ruleset.shared
    if rs.techs[icon] != nil || rs.nations[icon] != nil || rs.units[icon] != nil || rs.promotions[icon] != nil || rs.resources[icon] != nil { return icon }
    if let path = uncivNotificationIconPaths[icon] { return path }
    if rs.buildings[icon] != nil { return "BuildingIcons/" + icon }
    if rs.improvements[icon] != nil { return "ImprovementIcons/" + icon }
    return icon
}

/// Unciv NotificationIcon.getImage sırası: ruleset nesneleri (tech, ulus, birim, terfi, kaynak) önce,
/// sonra sabitin kendi yolu, en sonda düz doku yolu.
func notificationIconPath(_ icon: String, _ rs: Ruleset) -> String {
    if icon.contains("/") { return icon }
    if rs.techs[icon] != nil || rs.nations[icon] != nil || rs.units[icon] != nil
        || rs.promotions[icon] != nil || rs.resources[icon] != nil {
        return notificationIconFolder(icon, rs) + "/" + icon
    }
    if let path = uncivNotificationIconPaths[icon] { return path }
    return notificationIconFolder(icon, rs) + "/" + icon
}

/// Unciv ICivilopediaText.isHiddenFromCivilopedia: an object the ruleset hides is not listed at all.
func isHiddenFromCivilopedia(_ uniques: [String]) -> Bool {
    uniques.contains { Unique($0).pattern == "Will not be displayed in Civilopedia" }
}

// MARK: - Promotions

struct PromotionSheet: View {
    @ObservedObject var controller: GameController
    @State private var statusShown: String? = nil   // Unciv: the status whose description is being shown
    @State private var saveUnitPromotion = false   // Unciv PromotionPickerScreen.saveUnitPromotion: unticked on every visit
    @State private var renaming = false   // Unciv: UnitRenamePopup over the picker, which is recreated when it closes
    var body: some View {
        let s = controller.state
        if let u = controller.promotionUnit {   // Unciv PromotionPickerScreen(unit): the overview's row, or the selected unit
            let canChangeState = controller.isMyTurn && !s.player.isSpectator
            // Unciv UnitPromotions.xpForNextPromotion includes "[]% XP required for promotions"
            ThemedSheet(L("Pick promotion"), subtitle: "\(u.customName ?? L(u.name)) · XP \(u.currentXP)/\(s.xpCostForPromotionNumber(u.promotionNumber + 1, civId: u.civId))", onClose: { controller.showPromotions = false }) {
                // Unciv PromotionPickerScreen: "Choose name for [unit]" while the state may change
                if canChangeState {
                    Button(L("Choose name for [\(u.name)]")) { renaming = true }.buttonStyle(ThemedButtonStyle(compact: true))
                }
                // Unciv saveUnitPromotionForCity: inside one of our own non-puppet cities' territory
                if let city = s.owningCity(u.coord), city.civId == u.civId, !city.isPuppet {
                    Button { saveUnitPromotion.toggle() } label: { HStack(spacing: 6) { Image(systemName: saveUnitPromotion ? "checkmark.square.fill" : "square").foregroundStyle(Theme.gold); Text(L("Default promotions for [\(u.name)]")).font(Theme.caption) } }.buttonStyle(.plain)
                }
                // Unciv PromotionPickerScreen.addStatuses: temporary statuses with the turns they have left.
                if !u.statuses.isEmpty {
                    Panel(padding: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(u.statuses.sorted { $0.value < $1.value }, id: \.key) { name, left in
                                // Unciv PromotionPickerScreen.addStatuses: a status is a button that shows its rules text.
                                Button { statusShown = statusShown == name ? nil : name } label: {
                                    HStack(spacing: 6) { ArtIcon(name: name, folder: "PromotionIcons", fallback: "star", size: 18); Text(L("{\(name)}: \(left)⏳")).font(Theme.caption).foregroundStyle(Theme.cream); Spacer() }
                                }.buttonStyle(.plain)
                                if statusShown == name, let d = controller.state.rs.promotions[name] {
                                    ForEach(d.uniques.filter(isPlayerFacing), id: \.self) { u in Text(L(u)).font(Theme.small).foregroundStyle(Theme.creamDim).padding(.leading, 24) }
                                }
                            }
                        }
                    }
                }
                PromotionTreeView(controller: controller, unit: u, saveUnitPromotion: saveUnitPromotion)
            }
            .overlay { if renaming { RenamePopup(title: L("Choose name for [\(u.name)]"), initial: u.customName ?? L(u.name), validate: { $0 != u.name }, onDone: { n in if let n { controller.renameUnit(n, unitId: u.id) }; renaming = false }) } }
        } else {
            ThemedSheet(L("Promote"), onClose: { controller.showPromotions = false }) { EmptyView() }   // never shown without a unit in Unciv
        }
    }
}

// MARK: - Victory progress

