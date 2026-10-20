// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv UnitPresenter: the unit's numbers through Number.tr (`baseUnit.strength.tr()`, `XP.tr() + "/" + ...tr()`)
fileprivate func trNum(_ n: Int) -> String { Translations.shared.numberTr(n) }

/// Unciv UnitActionsTable: the selected unit's actions in Unciv's order (UnitActions.actionTypeToFunctions, then the
/// unmapped ones), split over two pages with "Show more" / "Back" (UnitActionType.defaultPage + actionTypeToPageGetter).
/// Unciv UnitTable's IdleUnitButtons (prev / next), on either side of the name whatever the table shows - unit, city, spy
/// or the summary: enabled while the civ hasIdleUnits, a tap selecting the previous / next idle unit
struct IdleUnitArrow: View {
    @ObservedObject var controller: GameController
    let previous: Bool
    var body: some View {
        Button { controller.idleArrow(previous: previous) } label: { Image(systemName: previous ? "chevron.left" : "chevron.right").foregroundStyle(controller.hasIdleUnits ? Theme.gold : Color.gray) }
            .buttonStyle(.plain).disabled(!controller.hasIdleUnits)
    }
}

struct UnitPanel: View {
    @ObservedObject var controller: GameController
    let unit: Unit

    // Unciv UnitActionsTable companion object.
    /// Maximum for how many pages there can be.
    private static let maxAllowedPages = 10
    /// Lower bound for how many buttons to distribute per page, including the navigation buttons.
    private static let minButtonsPerPage = 3
    /// Upper bound for the same, so a tall screen keeps some map visible between the actions and the top bar.
    private static let maxButtonsPerPage = 7
    /// Maximum number of buttons to present without paging, overriding the page preferences.
    private static let maxSinglePageButtons = 5
    /// Unciv padBetweenButtons.
    private static let padBetweenButtons: CGFloat = 3
    /// Height of one action button - the divisor of Unciv's updateButtonsPerPage.
    private static let actionButtonHeight: CGFloat = 30
    /// Everything the action column cannot use: the top bar, the unit table under it and both safe areas.
    /// Unciv measures `techPolicyAndDiplomacy.y - unitActionsTable.y`; on a phone that gap is the screen height
    /// minus the top bar, minus the unit table the column stands on, minus the notch and the home indicator.
    private static let reservedHeight: CGFloat = 320
    /// Width of the bottom left column. The bottom right corner (zoom + overlay toggles + minimap) needs about
    /// 200pt of an iPhone's 390, so this is a cap the HStack may still squeeze, not a fixed width.
    private static let columnWidth: CGFloat = 200

    /// Unciv UnitActionsTable.updateButtonsPerPage: `(availableHeight / buttonHeight)` clamped to 3…7.
    private var buttonsPerPage: Int {
        let available = UIScreen.main.bounds.height - Self.reservedHeight - Self.padBetweenButtons
        let fits = Int(available / (Self.actionButtonHeight + Self.padBetweenButtons))
        return min(Self.maxButtonsPerPage, max(Self.minButtonsPerPage, fits))
    }

    /// Unciv UnitActionsTable.update: the sorted actions are poured one by one into the bucket of their default
    /// page, moving on whenever a page is full (a page with neighbours reserves one slot for its navigation
    /// button); then, since that reservation can appear late, overflowing buttons are pushed to the front of the
    /// next page; and finally two pages that would fit into one are merged back together.
    private func paginate(_ sorted: [UnitAction]) -> [[UnitAction]] {
        let perPage = buttonsPerPage
        var buckets = [[UnitAction]](repeating: [], count: Self.maxAllowedPages)
        var numPages = 0
        func freeSlotsOnPage(_ page: Int) -> Int { perPage - buckets[page].count - (numPages > 1 ? 1 : 0) }
        for action in sorted {
            var actionPage = max(0, action.page)
            while actionPage < Self.maxAllowedPages && freeSlotsOnPage(actionPage) <= 0 { actionPage += 1 }
            if actionPage >= Self.maxAllowedPages { break }
            if actionPage >= numPages { numPages = actionPage + 1 }
            buckets[actionPage].append(action)
        }
        for page in 0..<(Self.maxAllowedPages - 1) {
            while freeSlotsOnPage(page) < 0 {
                let overflow = buckets[page].removeLast()
                buckets[page + 1].insert(overflow, at: 0)
                if numPages < page + 2 { numPages = page + 2 }
            }
        }
        if numPages == 2, perPage >= Self.maxSinglePageButtons, buckets[0].count + buckets[1].count <= Self.maxSinglePageButtons {
            buckets[0].append(contentsOf: buckets[1])
            buckets[1] = []
            numPages = 1
        }
        return Array(buckets.prefix(max(1, numPages)))
    }

    /// Hands each action its keyboard letter, first come first served over `taken`.
    private func withKeys(_ actions: [UnitAction], taken: inout Set<Character>) -> [UnitAction] {
        actions.map { a in
            var a = a
            let base = a.id.split(separator: "-").first.map(String.init) ?? a.id
            if let name = UnitAction.actionBindings[base], a.enabled, let k = KeyBindings.spec(name).equivalent {
                if !taken.contains(k.character) { taken.insert(k.character); a.key = k }
            }
            return a
        }
    }
    /// The visible page's actions with their keys, then the actions of every other page that answer to a key - Unciv
    /// UnitActionsTable.update, after pack(): "Bind all currently invisible actions to their keys", skipping the
    /// current page and any action whose `action` is null. The paging buttons shown keep their own keys.
    private func keyed(_ buckets: [[UnitAction]], page: Int) -> (visible: [UnitAction], hidden: [UnitAction]) {
        var taken = Set<Character>()
        let visible = withKeys(buckets[page], taken: &taken)
        if buckets.count > 1 {
            if page > 0, let k = KeyBindings.spec("Back").equivalent { taken.insert(k.character) }
            if page < buckets.count - 1, let k = KeyBindings.spec("Show more").equivalent { taken.insert(k.character) }
        }
        var hidden: [UnitAction] = []
        for p in buckets.indices where p != page {
            hidden += withKeys(buckets[p].filter { $0.enabled }, taken: &taken).filter { $0.key != nil }
        }
        return (visible, hidden)
    }

    var body: some View {
        let s = controller.state
        // Unciv UnitActionsTable: sortedByDescending { it.useFrequency }, which Kotlin sorts stably, so
        // actions of equal frequency keep the order they were produced in.
        let all = Self.actions(s, unit: unit, controller: controller).enumerated()
            .sorted { a, b in
                let fa = UnitAction.useFrequency[a.element.id.split(separator: "-").first.map(String.init) ?? a.element.id] ?? 0
                let fb = UnitAction.useFrequency[b.element.id.split(separator: "-").first.map(String.init) ?? b.element.id] ?? 0
                return fa != fb ? fa > fb : a.offset < b.offset
            }
            .map { $0.element }
        let buckets = paginate(all)
        // Unciv UnitActionsTable.update: "if (currentPage !in 0 until numPages) currentPage = 0"
        let page = buckets.indices.contains(controller.unitActionPage) ? controller.unitActionPage : 0
        // Unciv UnitActionsTable.update: "if (!worldScreen.canChangeState) return" - outside our turn
        // (and for a spectator) the unit keeps its info row but offers no action buttons.
        let canChangeState = controller.isMyTurn && !s.player.isSpectator
        let keyedActions = keyed(buckets, page: page)
        // Unciv WorldScreen: `unitActionsTable.y = bottomUnitTable.height` - the actions are a vertical list
        // standing on top of the unit table, both in the bottom left corner of the screen.
        VStack(alignment: .leading, spacing: Self.padBetweenButtons) {
            if canChangeState {
                // Unciv slides its action buttons in rather than having them appear in place (UnitActionsTable
                // adds a moveBy and an alpha with a per-button delay). The easing is ours; the point is that a
                // list which changes as you play should be seen to change, not silently swap under the finger.
                ForEach(keyedActions.visible) { a in
                    button(a).transition(.move(edge: .leading).combined(with: .opacity))
                }
                .animation(.easeOut(duration: 0.16), value: buckets[page].count)
                // Unciv: "if (currentPage > 0) add(previousPageButton); if (currentPage < numPages - 1) add(nextPageButton)"
                if buckets.count > 1 {
                    HStack(spacing: Self.padBetweenButtons) {
                        if page > 0 { button(UnitAction(id: "back", title: L("Back"), icon: "arrow.uturn.left", key: KeyBindings.spec("Back").equivalent) { controller.unitActionPage = (page - 1 + buckets.count) % buckets.count }) }
                        if page < buckets.count - 1 { button(UnitAction(id: "more", title: L("Show more"), icon: "ellipsis", key: KeyBindings.spec("Show more").equivalent) { controller.unitActionPage = (page + 1) % buckets.count }) }
                    }
                }
            }
            unitInfoTable(s)
        }
        // Unciv: the enabled actions of the pages not shown still answer to their keys (a Worker's Explore, Disband) -
        // unless a popup or another screen is up (KeyShortcutDispatcherVeto: SkipWithChildren outside the popup)
        .background {
            if canChangeState && !controller.worldShortcutsVetoed {
                Group {
                    ForEach(keyedActions.hidden) { a in
                        if let k = a.key { Button("") { activate(a, playSound: false) }.keyboardShortcut(k, modifiers: []) }
                    }
                }
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: Self.columnWidth, alignment: .leading)
    }

    /// Unciv UnitTable (`bottomUnitTable`): the selected unit's icon, name, stats and promotions.
    private func unitInfoTable(_ s: GameState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Unciv UnitTable.moveBetweenUnitsTable: previous idle unit, the unit's icon and name, next idle unit - one row
            HStack(spacing: 8) {
                IdleUnitArrow(controller: controller, previous: true)
                // Unciv UnitPresenter: unitIconHolder.onClick → the unit's Civilopedia page
                Button { controller.civilopediaEntry = "Unit/\(unit.name)"; controller.showCivilopedia = true } label: { ArtIcon(name: unit.name, folder: "Units", fallback: "person.fill", size: 30) }.buttonStyle(.plain)
                // Unciv UnitPresenter.buildNameLabelText: display name (+ religion) and the health in brackets when wounded.
                Button { if controller.isMyTurn && !s.player.isSpectator { controller.showRenameUnit = true } } label: { Text((unit.customName.map { "\($0) (\(L(unit.name)))" } ?? L(unit.name)) + (unit.religion.map { " (\(L($0)))" } ?? "") + (unit.health < 100 ? " (\(unit.health))" : "")).font(Theme.heading(15)).foregroundStyle(Theme.gold).lineLimit(1) }.buttonStyle(.plain)
                IdleUnitArrow(controller: controller, previous: false)
            }
            VStack(alignment: .leading, spacing: 1) {
                // Unciv descriptionTable: movement, strength, ranged strength + range, intercept range, XP xp/next (tap → promotions), religious strength.
                HStack(spacing: 8) {
                    Text("👟" + L(Self.movementString(s, unit))).font(Theme.small).foregroundStyle(Theme.creamDim)
                    if unit.isMilitary { Text("⚔️" + trNum(unit.def.strength)).font(Theme.small).foregroundStyle(Theme.creamDim) }
                    if unit.def.rangedStrength != 0 { Text("🏹" + trNum(unit.def.rangedStrength)).font(Theme.small).foregroundStyle(Theme.creamDim) }
                    if unit.def.isRanged { Text("…" + trNum(s.attackRange(unit))).font(Theme.small).foregroundStyle(Theme.creamDim) }
                    let interceptionRange = s.interceptionRange(unit)
                    if interceptionRange > 0 { Text("🛡" + trNum(interceptionRange)).font(Theme.small).foregroundStyle(Theme.creamDim) }
                    if unit.isMilitary { Button { controller.showPromotions = true } label: { Text(L("XP") + " " + trNum(unit.currentXP) + "/" + trNum(unit.xpForNextPromotion)).font(Theme.small).foregroundStyle(!s.availablePromotions(for: unit).isEmpty ? Theme.gold : Theme.creamDim) }.buttonStyle(.plain) }
                    if unit.def.religiousStrength > 0 { Text("☮\(max(0, unit.def.religiousStrength - unit.religiousStrengthLost))").font(Theme.small).foregroundStyle(Theme.creamDim) }
                }.lineLimit(1)
                // Unciv promotionsTable: promotion portraits plus statuses with their turns left; tap → PromotionPickerScreen.
                if !unit.promotions.isEmpty || !unit.statuses.isEmpty {
                    Button { controller.showPromotions = true } label: {
                        HStack(spacing: 3) {
                            // Unciv getPromotions(sorted = true): ruleset order once there are several; "Not shown on world screen" skipped
                            ForEach(Self.stripPromotions(s, unit), id: \.self) { p in ArtIcon(name: p, folder: "PromotionIcons", fallback: "star", size: 18) }
                            // Unciv statusMap.values: HashMap order
                            ForEach(javaHashMapOrder(Array(unit.statuses.keys)).filter { s.rs.promotions[$0]?.uniques.contains("Not shown on world screen") != true }.map { ($0, unit.statuses[$0] ?? 0) }, id: \.0) { name, left in ZStack(alignment: .bottomTrailing) { ArtIcon(name: name, folder: "PromotionIcons", fallback: "star", size: 18); Text("\(left)⏳").font(.system(size: 7, weight: .bold)).padding(1).background(Circle().fill(Color.black.opacity(0.8))) } }
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [Theme.panelLight.opacity(0.95), Theme.panel.opacity(0.95)], startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 5, y: 3)
        .foregroundStyle(Theme.cream)
        // Unciv UnitTable: a tap on the table centres the map on the unit (setCenterPosition, selectUnit = false)
        .contentShape(Rectangle())
        .onTapGesture { controller.setCenterPosition(unit.coord, selectUnit: false); controller.refresh(full: false) }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Unciv UnitTable closeButton (addRoundCloseButton): deselect, in the table's corner
        .overlay(alignment: .topTrailing) {
            Button { controller.selectedUnitId = nil; controller.refresh(full: false) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.gold) }.buttonStyle(.plain)
                .offset(x: 6, y: -6)
        }
    }

    /// Unciv MapUnit.getMovementString: DecimalFormat("0.#") of the movement left, "/", the Int maximum
    /// MapUnit.getMovementString: `(DecimalFormat("0.#").format(currentMovement) + "/" + getMaxMovement()).tr()` - the
    /// decimal in the device's locale (Unciv sets no default Locale), the tr() left to the caller
    static func movementString(_ s: GameState, _ unit: Unit) -> String {
        let f = NumberFormatter(); f.minimumFractionDigits = 0; f.maximumFractionDigits = 1; f.roundingMode = .halfEven; f.minimumIntegerDigits = 1
        return (f.string(from: NSNumber(value: unit.movementLeft)) ?? "0") + "/" + "\(Int(s.maxMovement(of: unit)))"
    }
    static func stripPromotions(_ s: GameState, _ unit: Unit) -> [String] {
        let names = unit.promotions.count > 1 ? s.rs.promotionOrder.map(\.name).filter { unit.promotions.contains($0) } : unit.promotions
        return names.filter { s.rs.promotions[$0].map { !$0.uniques.contains("Not shown on world screen") } ?? false }
    }

    // MARK: Unciv's action list
    /// Static so the turn dump can list any civilization's unit without a GameController (UACT): with no controller
    /// the UI-only states (paradrop, sweep, road and swap modes) read as off and the actions do nothing.
    static func actions(_ s: GameState, unit: Unit, controller: GameController?) -> [UnitAction] {
        let civ = s.civ(unit.civId) ?? s.player
        let tile = s.map[unit.coord]
        var out: [UnitAction] = []
        let canAct = unit.movementLeft > 0
        // --- actionTypeToFunctions order
        for t in s.transformTargets(unit) { out.append(UnitAction(id: "transform-\(t.name)", title: L("Transform to [\(t.name)]"), icon: "arrow.triangle.2.circlepath", enabled: canAct && !s.isEmbarked(unit)) { controller?.transformSelected(to: t.name) }) }
        // A tile-picking mode (paradrop, air sweep, connect road, swap) keeps its action's own title and is shown as the current
        // action (UnitAction.isCurrentAction), as Unciv's button does - no "pick tile" title
        // Unciv getParadropActions: offered while a "May Paradrop" unique applies where the unit stands, usable until it moves this turn
        if unit.def.uniqueObjects.contains(where: { u in u.pattern == "May Paradrop to [] tiles up to [] tiles away" && (u.conditional("in [] tiles").map { c in s.map[unit.coord].map { s.tileMatches($0, c.param(0), civId: unit.civId) } ?? false } ?? true) }) { out.append(UnitAction(id: "paradrop", title: L("Paradrop"), icon: "arrow.down.to.line", enabled: unit.movementLeft >= s.maxMovement(of: unit) - 0.001, isCurrent: (controller?.paradropMode ?? false)) { controller?.paradropMode.toggle(); controller?.refresh(full: false) }) }
        // Unciv getAirSweepActions: `.takeIf { unit.canAttack() }` - movement left (hasMovement) and attacks left this turn
        if unit.def.canAirSweep { out.append(UnitAction(id: "sweep", title: L("Air Sweep"), icon: "wind", enabled: canAct && unit.attacksThisTurn < 1 + s.extraAttacks(of: unit), isCurrent: (controller?.sweepMode ?? false)) { controller?.sweepMode.toggle() }) }
        if unit.def.mustSetUp, !s.isEmbarked(unit) { out.append(UnitAction(id: "setup", title: L("Set up"), icon: "scope", enabled: canAct && !unit.isSetUp, isCurrent: unit.isSetUp) { controller?.setUpSelected() }) }
        // Unciv getGuardActions: while guarding, a current action with no action (a disabled button) titled with the raw
        // fortification turns (getFortificationTurns, 0% on the turn it starts) when the unit can fortify; otherwise
        // nothing at all without movement, and Guard.
        if s.canGuard(unit) {
            if s.isGuarding(unit) {
                let title = s.canFortify(unit) ? "\(L("Guarding")) \(unit.turnsFortified * 20)%" : L("Guarding")
                out.append(UnitAction(id: "guard", title: title, icon: "shield.lefthalf.filled", enabled: false, isCurrent: true) {})
            } else if unit.hasMovement {
                out.append(UnitAction(id: "guard", title: L("Guard"), icon: "shield.lefthalf.filled") { controller?.guardSelected() })
            }
        }
        if unit.def.isSettler && !(tile?.isWater ?? true) && !(tile?.isImpassable ?? true) && !(s.settings.oneCityChallenge && civ.isPlayer && civ.hasEverOwnedOriginalCapital) { out.append(UnitAction(id: "found", title: L("Found city"), icon: "flag.fill", enabled: s.canFoundCity(at: unit.coord, civId: unit.civId) && unit.movementLeft > 0) { controller?.foundCity() }) }   // Unciv getFoundCityAction: no button on water or impassable ground
        if unit.def.isWorker || !unit.def.improvementFilters.isEmpty, let t = tile {
            // Unciv getBuildingImprovementsActions: always offered to a unit that builds improvements; usable with movement
            // left, off a city centre, when the picker would list something this unit can build here (every problem of it
            // one the picker reports). The tile's work in progress marks it current.
            let couldConstruct = unit.hasMovement && !t.isCityCenter && s.rs.improvements.values.contains { imp in
                s.improvementBuildingProblems(imp, civId: unit.civId, tile: t, unit: unit).allSatisfy { $0.reportable } && s.unitCanBuildImprovement(unit, imp.name, t)
            }
            let building: String? = { if case .build(let b) = unit.order { return b }; return nil }()
            out.append(UnitAction(id: "construct", title: building.map { "\(L($0)) \(t.improvementTurnsLeft)t" } ?? L("Construct improvement"), icon: "hammer.fill", enabled: couldConstruct, isCurrent: t.improvementInProgress != nil) { controller?.showImprovementPicker = true })
        // Unciv UnitActionsFromUniques.getRepairAction: a unit whose BuildImprovements filter matches the pillaged
        // improvement (or the terrain) is offered Repair, usable only when couldConstruct - which a Repair already under
        // way and a tile outside our borders both refuse. The action queues the repair behind the work in progress.
        if let repair = s.repairAction(unit.id) {
            out.append(UnitAction(id: "repair", title: L("Repair [\(repair.toRepair)] - [\(s.repairTurns(unit))⏳]"), icon: "wrench.and.screwdriver.fill",
                                  enabled: repair.couldConstruct) { controller?.repairSelected() })
        }
        }
        if s.canConnectRoad(unit) { out.append(UnitAction(id: "connectroad", title: L("Connect road"), icon: "road.lanes", isCurrent: s.isConnectingRoad(unit) || (controller?.connectRoadMode ?? false)) { controller?.connectRoadMode.toggle(); controller?.refresh(full: false) }) }
        // Unciv UnitActionsGreatPerson: one button per unique the unit has, disabled rather than hidden when it cannot act now
        let hasMove = unit.movementLeft > 0
        let cityHere = s.city(at: unit.coord)
        let centerHere = s.map[unit.coord]?.isCityCenter == true
        let currentBuilding: BuildingDef? = { if case .building(let b)? = cityHere?.currentProduction { return s.rs.buildings[b] }; return nil }()
        if unit.def.uniques.contains("Can hurry technology research") {
            let ok = hasMove && civ.currentTech != nil && s.rs.techs[civ.currentTech ?? ""]?.uniques.contains("Cannot be hurried") != true
            out.append(UnitAction(id: "hurryresearch", title: "\(L("Hurry Research")) (☠)", icon: "sparkles", enabled: ok) { controller?.greatPersonAction(.hurryTech) })
        }
        if unit.def.uniques.contains("Can generate a large amount of culture") { out.append(UnitAction(id: "hurrypolicy", title: "\(L("Hurry Policy")) (☠)", icon: "sparkles", enabled: hasMove) { controller?.greatPersonAction(.hurryPolicy) }) }
        if unit.def.uniques.contains("Can speed up the construction of a wonder") {
            // canHurryWonder: a city centre building a wonder that can be hurried
            let canHurryWonder = centerHere && currentBuilding?.isWonder == true && currentBuilding?.uniques.contains("Cannot be hurried") != true
            // Unciv UnitActionType.HurryWonder's own title "{Hurry Wonder} (☠)" - getHurryWonderActions passes none
            out.append(UnitAction(id: "hurrywonder", title: L("{Hurry Wonder} (☠)"), icon: "sparkles", enabled: hasMove && canHurryWonder) { controller?.greatPersonAction(.hurryProduction) })
        }
        if unit.def.uniques.contains("Can speed up construction of a building") {
            if !centerHere { out.append(UnitAction(id: "hurrybuilding", title: L("{Hurry Construction} (☠)"), icon: "sparkles", enabled: false) {}) }
            else if let c = cityHere {
                let points = s.hurryProductionPoints(for: c)
                if points > 0 {
                    let canHurry = currentBuilding != nil && currentBuilding?.uniques.contains("Cannot be hurried") != true
                    out.append(UnitAction(id: "hurrybuilding", title: L("Hurry Construction (+[\(points)]⚙)"), icon: "sparkles", enabled: hasMove && canHurry) { controller?.greatPersonAction(.hurryProduction) })
                }
            }
        }
        if unit.def.uniqueObjects.contains(where: { $0.pattern == "Can undertake a trade mission with City-State, giving a large sum of gold and [] Influence" }) {
            let owner = s.map[unit.coord]?.ownerCivId.flatMap { s.civ($0) }
            let canConduct = owner?.isCityState == true && owner?.id != unit.civId && owner.map { !s.areAtWar($0.id, unit.civId) } == true
            out.append(UnitAction(id: "trademission", title: "\(L("Conduct Trade Mission")) (☠)", icon: "sparkles", enabled: hasMove && canConduct) { controller?.greatPersonAction(.tradeMission) })
        }
        // Unciv getFoundReligionActions / getEnhanceReligionActions: shown while the civ may found (enhance) at all, usable here and now
        // "May found (enhance) a religion <by consuming this unit> <if it hasn't used other actions yet>": the unique only
        // counts while no other action was used (abilityToTimesUsed empty); the title carries the side effect "(☠)"
        // (actionTextWithSideEffects); canActivateSideEffects asks for 1 movement point. The action spends the prophet
        // and puts the civ into FoundingReligion / EnhancingReligion - the beliefs are picked from the next-turn button.
        let prophetUnused = unit.abilityToTimesUsed.isEmpty
        if unit.def.canFoundReligion && prophetUnused && s.canFoundReligion(civ) { out.append(UnitAction(id: "foundreligion", title: L("Found a Religion") + " (☠)", icon: "sparkles", enabled: s.city(at: unit.coord).map { !$0.isHolyCity } == true && unit.movementLeft > 0) { controller?.useProphetForFoundingReligion() }) }
        if unit.def.canEnhanceReligion && prophetUnused && s.mayEnhanceReligion(civ) { out.append(UnitAction(id: "enhance", title: L("Enhance [\(civ.religionDisplayName ?? civ.religionName ?? "")]") + " (☠)", icon: "sparkles", enabled: s.map[unit.coord]?.isCityCenter == true && unit.movementLeft > 0) { controller?.useProphetForEnhancingReligion() }) }
        // Unciv getImprovementCreationActions: the water improvement a work boat makes here, then every improvement an
        // "instantly construct" unique names that this tile could ever take - disabled while it cannot be built now
        if let t = s.map[unit.coord] {
            if let imp = s.waterImprovement(for: unit) {   // getWaterImprovementAction (no movement asked there)
                out.append(UnitAction(id: "create-\(imp)", title: L("Create [\(imp)]"), icon: "sparkles", enabled: hasMove) { controller?.greatPersonAction(.improvement) })
            }
            for u in unit.def.uniqueObjects where u.pattern == "Can instantly construct a [] improvement" && s.conditionalsHold(u, GameState.UniqueContext(civId: unit.civId, unit: unit, tile: t)) && (s.actionUsesLeft(unit, u) ?? 1) > 0 {
                for imp in s.rs.improvements.values.sorted(by: { $0.name < $1.name }) where s.improvementMatches(imp.name, u.param(0)) {
                    let problems = s.improvementBuildingProblems(imp, civId: unit.civId, tile: t, unit: unit)
                    if problems.contains(where: { $0.permanent }) { continue }
                    let ok = s.improvementResourcesAvailable(imp, civId: unit.civId) && hasMove && problems.isEmpty && !s.isMarkedForCreatesOneImprovement(unit.coord)
                    out.append(UnitAction(id: "create-\(imp.name)", title: L("Create [\(imp.name)]"), icon: "sparkles", enabled: ok) { controller?.greatPersonAction(imp.name == "Citadel" ? .citadel : .improvement) })
                }
            }
        }
        // Unciv getSpreadReligionActions: offered in any city's territory to a unit that may spread at all; maySpreadReligionNow
        // asks no movement
        // The title is actionTextWithSideEffects("Spread [religion display name]") over the first usable Can Spread
        // Religion unique (getUsableUnitActionUniques: no "additional time(s)" modifier, uses left).
        if s.maySpreadReligionAtAll(unit), let oc = s.owningCity(unit.coord), let spreadUnique = s.firstUsableActionUnique(unit, "Can Spread Religion") {
            out.append(UnitAction(id: "spread", title: s.actionTextWithSideEffects("Spread [\(s.religionDisplayName(unit.religion ?? ""))]", spreadUnique, unit), icon: "flame", enabled: s.canSpread(unit, at: oc.coord, needMovement: false)) { controller?.spreadReligion() })
        }
        // Unciv getRemoveHeresyActions: offered in our own city's territory while the city holds another religion's
        // pressure; usable only when canActivateSideEffects (a movement point), so with no movement left it is shown disabled.
        // The title is actionTextWithSideEffects("Remove Heresy") over the CanRemoveHeresy unique.
        if unit.def.canRemoveReligions, let oc = s.owningCity(unit.coord), s.canRemoveHeresy(unit, at: oc.coord, needMovement: false),
           let heresyUnique = s.firstUsableActionUnique(unit, "Can remove other religions from cities") {
            out.append(UnitAction(id: "heresy", title: s.actionTextWithSideEffects("Remove Heresy", heresyUnique, unit), icon: "flame.fill", enabled: s.canRemoveHeresy(unit, at: oc.coord)) { controller?.removeHeresy() })
        }
        // Unciv getTriggerUniqueActions: a unit unique with an action modifier that triggers something - here the Golden Age
        // The title is getTriggerUniqueActions' for OneTimeEnterGoldenAgeTurns: the placeholder text filled with
        // calculateGoldenAgeLength(params[0]).tr(), through actionTextWithSideEffects
        if let golden = unit.def.uniqueObjects.first(where: { $0.pattern == "Empire enters a []-turn Golden Age" && (s.actionUsesLeft(unit, $0) ?? 1) > 0 }) { out.append(UnitAction(id: "golden", title: s.actionTextWithSideEffects("Empire enters a [\(s.calculateGoldenAgeLength(unit.civId, golden.int(0)))]-turn Golden Age", golden, unit), icon: "sparkles", enabled: hasMove) { controller?.greatPersonAction(.goldenAge) }) }
        if s.canAddSpaceshipPart(unit) { out.append(UnitAction(id: "capital", title: L("Add in capital"), icon: "airplane.departure") { controller?.addSpaceshipPart() }) }
        if let recipient = s.giftRecipient(unit) { out.append(UnitAction(id: "gift", title: "\(L("Gift unit")) → \(L(recipient.nation))", icon: "gift.fill", page: 1, enabled: canAct) { controller?.giftSelected() }) }
        // --- unmapped actions (UnitActions.addUnmappedUnitActions)
        // Unciv MapUnit.isAutomated() is its own `automated` flag: set by Automate and by Connect road
        // (OverlayButtonData.connectRoadToTargetTile: `action = ConnectRoad; automated = true`), never by Explore.
        let automated = unit.isAutomated
        if !automated, unit.def.isWorker || unit.def.uniques.contains("May create improvements on water resources") || !unit.def.improvementFilters.isEmpty {
            out.append(UnitAction(id: "automate", title: L("Automate"), icon: "gearshape.2.fill", page: unit.def.automationIsPrimaryAction || unit.def.isWorker ? 0 : 1, enabled: unit.hasMovement) { controller?.automateSelected() })
        } else if !automated {
            // Unciv UnitActions.addAutomateActions: any unit not already automated, usable while it has movement
            out.append(UnitAction(id: "automate", title: L("Automate"), icon: "gearshape.2.fill", page: 1, enabled: unit.hasMovement) { controller?.automateSelected() })
        }
        // Unciv MapUnit.isMoving(): `action?.startsWith("moveTo")` - a road-connecting worker's action is "ConnectRoad"
        let moving: Bool = { if case .moveTo = unit.order { return true }; return false }()
        if moving { out.append(UnitAction(id: "stopmove", title: L("Stop movement"), icon: "stop.fill") { controller?.stopOrders() }) }
        if unit.order == .explore { out.append(UnitAction(id: "stopexplore", title: L("Stop exploration"), icon: "stop.fill") { controller?.stopOrders() }) }
        if automated { out.append(UnitAction(id: "stopauto", title: L("Stop automation"), icon: "stop.fill") { controller?.stopAutomation() }) }
        // Unciv addPromoteActions: only when canBePromoted - a non-empty available list, and enough XP for the next
        // promotion (with the civ's cost modifier) or a free one among them, which availablePromotions(for:) is -
        // enabled while it has movement and has not attacked this turn. A promotion-less Guided Missile built with
        // Barracks XP got a Promote button that opened an empty picker.
        if !s.availablePromotions(for: unit).isEmpty { out.append(UnitAction(id: "promote", title: L("Promote"), icon: "star.fill", enabled: unit.hasMovement && unit.attacksThisTurn == 0) { controller?.showPromotions = true }) }
        // Unciv UnitActionsUpgrade.getUpgradeActions: one action per upgrade the unit may take inside our own
        // borders, listed with ignoreResources so a missing resource leaves a disabled button (whose menu still
        // opens) instead of no button at all. A tap upgrades, a long press opens the UnitUpgradeMenu.
        if s.map[unit.coord]?.ownerCivId == unit.civId {
            for target in UnitUpgradeMenuView.upgradeTargets(s, unit) {
                let cost = s.upgradeCost(unit, to: target)
                let need = UnitUpgradeMenuView.newResourceRequirements(s, unit, to: target).sorted { $0.key < $1.key }.map { "\($0.value) \(L($0.key))" }.joined(separator: ", ")
                // Unciv puts the new resource requirement in the title beside the gold cost, on a second line:
                // "Upgrade to [X]\n([cost] gold, [res])" is its own translation key.
                let title = need.isEmpty ? L("Upgrade to [\(target.name)] ([\(cost)] gold)") : L("Upgrade to [\(target.name)]\n([\(cost)] gold, [\(need)])")
                out.append(UnitAction(id: "upgrade-\(target.name)", title: title, icon: "arrow.up.circle.fill", enabled: canAct && UnitUpgradeMenuView.canPerform(s, unit, to: target), longPress: { controller?.showUpgradeMenu = true }) { controller?.upgradeUnit(unit.id, to: target) })
            }
        }
        // Unciv getPillageAction: offered to a military unit on a pillageable improvement outside its own borders, usable
        // with movement left and canPillage
        if !unit.isCivilian, let target = s.map[unit.coord]?.improvementToPillage, s.map[unit.coord]?.ownerCivId != unit.civId { out.append(UnitAction(id: "pillage", title: L("Pillage [\(target)]"), icon: "flame.fill", enabled: canAct && s.canPillage(unit)) { controller?.confirmPillage = target }) }
        let sleeping = unit.order == .sleep, sleepingHealed = unit.order == .sleepUntilHealed
        let fortified = unit.order == .fortify, fortifiedHealed = unit.order == .fortifyUntilHealed
        let wounded = unit.health < 100
        // Unciv UnitActions.addFortifyActions: an already-fortified unit yields exactly one button and nothing
        // else - no way to switch to "until healed" - and its percentage is the raw fortification turns, which
        // is zero on the turn you fortify.
        let anyFortified = fortified || fortifiedHealed
        if anyFortified {
            let title = "\(L("Fortification")) \(min(2, unit.turnsFortified) * 20)%"
            // Unciv: the current fortification is shown, with no action - a disabled button
            out.append(UnitAction(id: fortifiedHealed ? "fortifyhealedcurrent" : "fortifycurrent", title: title, icon: "shield.fill", page: 0, enabled: false, isCurrent: true) {})
        } else if s.canFortify(unit), unit.hasMovement {
            out.append(UnitAction(id: "fortify", title: L("Fortify"), icon: "shield.fill", page: wounded ? 1 : 0) { controller?.order(.fortify) })
            // Unciv gates this on canHealInCurrentTile, and disables rather than hides it.
            if wounded { out.append(UnitAction(id: "fortifyhealed", title: L("Fortify until healed"), icon: "cross.circle.fill", page: 0, enabled: s.healAmountForCurrentTile(unit) > 0) { controller?.order(.fortifyUntilHealed) }) }
        }
        // Unciv addSleepActions: nothing at all for a unit that can fortify, is guarding, or is out of moves,
        // nor for a worker standing on an improvement it is building.
        // Unciv: `tile.hasImprovementInProgress() && unit.canBuildImprovement(tile.getTileImprovementInProgress())`
        let buildingHere = s.map[unit.coord].map { t in t.improvementInProgress.map { s.unitCanBuildImprovement(unit, $0, t) } ?? false } ?? false
        if !anyFortified && !s.canFortify(unit) && !s.isGuarding(unit) && unit.hasMovement && !buildingHere {
            out.append(UnitAction(id: sleeping ? "sleepcurrent" : "sleep", title: L("Sleep"), icon: "moon.zzz.fill", page: (sleepingHealed || wounded && !sleeping) ? 1 : 0, enabled: !(sleeping || sleepingHealed) || sleepingHealed, isCurrent: sleeping) { if !sleeping { controller?.order(.sleep) } })
            if wounded { out.append(UnitAction(id: sleepingHealed ? "sleephealedcurrent" : "sleephealed", title: L("Sleep until healed"), icon: "bed.double.fill", page: sleeping ? 1 : 0, enabled: !sleepingHealed && s.healAmountForCurrentTile(unit) > 0, isCurrent: sleepingHealed) { if !sleepingHealed { controller?.order(.sleepUntilHealed) } }) }
        }
        if !unit.def.isAir && unit.order != .explore { out.append(UnitAction(id: "explore", title: L("Explore"), icon: "binoculars.fill", page: unit.isCivilian ? 1 : 0) { controller?.explore(unit.id) }) }
        out.append(UnitAction(id: "skip", title: L("Skip turn"), icon: "forward.fill", enabled: unit.movementLeft > 0, isCurrent: !unit.due) { controller?.skipUnit() })
        // --- second page by default
        if moving { out.append(UnitAction(id: "dest", title: L("Show unit destination"), icon: "mappin.and.ellipse", page: 1) { controller?.showUnitDestination() }) }
        if s.canEscort(unit) {
            if s.isEscorting(unit) { out.append(UnitAction(id: "stopescort", title: L("Stop Escort formation"), icon: "link.badge.plus", page: 1, isCurrent: true) { controller?.stopEscort() }) }
            else { out.append(UnitAction(id: "escort", title: L("Escort formation"), icon: "link", page: 1) { controller?.startEscort() }) }
        }
        if !s.units.filter({ s.canSwap(unit, with: $0) }).isEmpty { out.append(UnitAction(id: "swap", title: L("Swap units"), icon: "arrow.left.arrow.right", page: 0, isCurrent: controller?.swapMode ?? false) { controller?.swapMode.toggle(); controller?.refresh(full: false) }) }
        out.append(UnitAction(id: "disband", title: L("Disband unit"), icon: "trash", page: 1, enabled: unit.movementLeft > 0) { controller?.disbandUnit() })
        return out
    }

    /// Our action ids as Unciv's UnitActionType names
    static func uncivType(_ id: String) -> String? {
        let table: [String: String] = ["paradrop": "Paradrop", "sweep": "AirSweep", "setup": "SetUp", "guard": "Guard", "found": "FoundCity",
            "construct": "ConstructImprovement", "repair": "Repair", "connectroad": "ConnectRoad", "hurryresearch": "HurryResearch",
            "hurrypolicy": "HurryPolicy", "hurrywonder": "HurryWonder", "hurrybuilding": "HurryBuilding", "trademission": "ConductTradeMission",
            "foundreligion": "FoundReligion", "enhance": "EnhanceReligion", "spread": "SpreadReligion", "heresy": "RemoveHeresy",
            "golden": "TriggerUnique", "capital": "AddInCapital", "gift": "GiftUnit", "automate": "Automate", "stopmove": "StopMovement",
            "stopexplore": "StopExploration", "stopauto": "StopAutomation", "promote": "Promote", "pillage": "Pillage",
            "fortifycurrent": "Fortify", "fortifyhealedcurrent": "FortifyUntilHealed", "fortify": "Fortify", "fortifyhealed": "FortifyUntilHealed", "sleep": "Sleep", "sleepcurrent": "Sleep",
            "sleephealed": "SleepUntilHealed", "sleephealedcurrent": "SleepUntilHealed", "explore": "Explore", "skip": "Skip",
            "dest": "ShowUnitDestination", "escort": "EscortFormation", "stopescort": "StopEscortFormation", "swap": "SwapUnits", "disband": "DisbandUnit",
            "more": "ShowAdditionalActions", "back": "HideAdditionalActions"]
        if id.hasPrefix("transform-") { return "Transform" }
        if id.hasPrefix("create-") { return "CreateImprovement" }
        if id.hasPrefix("upgrade-") { return "Upgrade" }
        return table[id]
    }
    /// Unciv UnitActionType.isSkippingToNextUnit (true unless the type says false)
    static func isSkippingToNextUnit(_ type: String?) -> Bool {
        guard let t = type else { return false }
        return !["StopEscortFormation", "EscortFormation", "SwapUnits", "ConnectRoad", "StopAutomation", "StopMovement", "ShowUnitDestination",
                 "StopExploration", "Promote", "Pillage", "Paradrop", "AirSweep", "SetUp", "ConstructImprovement", "CreateImprovement",
                 "TriggerUnique", "DisbandUnit", "ShowAdditionalActions", "HideAdditionalActions"].contains(t)
    }
    /// Unciv UnitActionType.uncivSound (Click unless the type names another; Silent plays nothing)
    static func sound(_ type: String?) -> String? {
        switch type {
        case "Fortify", "FortifyUntilHealed", "Guard": return "fortify"
        case "Promote": return "promote"
        case "Upgrade", "Transform": return "upgrade"
        case "SetUp": return "setup"
        case "FoundCity", "GiftUnit", "Skip": return nil
        case "Repair": return "construction"
        case "CreateImprovement", "HurryResearch", "HurryPolicy", "HurryWonder", "HurryBuilding", "ConductTradeMission", "TriggerUnique", "AddInCapital": return "chimes"
        case "FoundReligion", "SpreadReligion", "EnhanceReligion": return "choir"
        case "RemoveHeresy": return "fire"
        default: return "click"
        }
    }

    /// Unciv UnitActionsTable.activateAction: the action's sound, the action, the move overlay closed, then with Auto
    /// Unit Cycle on the next unit when this one is gone or the type skips (and it is not moving or out of movement).
    /// A button and a key of a page not shown go the same way; only the button (onActivation(uncivSound, binding))
    /// plays the sound - the hidden page's `keyShortcuts.add(binding) { activateAction(..) }` has none.
    private func activate(_ a: UnitAction, playSound: Bool = true) {
        guard a.enabled else { return }
        // a key passed up from a sheet or cover presented over the world (a tap cannot reach this under one)
        guard !FunctionKeys.rootIsCovered else { return }
        UnitPanel.activate(a, controller: controller, playSound: playSound)
    }
    /// Unciv UnitActionsTable.activateAction: the action, then the overlay closed and, with Auto Unit Cycle, the next unit
    /// (also `--replay-human`'s press of a button)
    static func activate(_ a: UnitAction, controller: GameController, playSound: Bool = true) {
        let type = UnitPanel.uncivType(a.id)
        if playSound, let snd = UnitPanel.sound(type) { Audio.shared.play(snd) }
        let unitId = controller.selectedUnitId
        a.action()
        // removeUnitActionOverlay: the Move here and Paradrop buttons and the unit icons of the last tap
        controller.pendingMove = nil; controller.paradropOverlay = nil; controller.unitIconsTile = nil
        controller.afterUnitAction(unitId, skipping: UnitPanel.isSkippingToNextUnit(type))
    }

    private func button(_ a: UnitAction) -> some View {
        // Unciv UnitActionsTable: the Upgrade button is force-enabled even while the upgrade is disabled, so its
        // context menu still opens and can show what the upgrade would give - only the click itself is ignored.
        let keepTouchable = a.longPress != nil
        // Unciv UnitActionsTable.activateAction: doing anything with a unit closes the move-here overlay; the paging
        // buttons are UnitActions too (ShowAdditionalActions / HideAdditionalActions) and close it as well.
        return Button {
            activate(a)
        } label: {
            // Unciv IconTextButton: the action icon, then its title, on a single row (two lines where the title
            // carries Unciv's "\n", as the upgrade needing a new resource does).
            HStack(spacing: 6) { Image(systemName: a.icon).font(.system(size: 12)).frame(width: 15); Text(a.title).font(.system(size: 10, weight: .semibold)).lineLimit(a.title.contains("\n") ? 2 : 1).minimumScaleFactor(0.6); Spacer(minLength: 0) }
                .foregroundStyle(a.enabled ? (a.isCurrent ? Theme.panelDark : Theme.cream) : Theme.creamDim)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: Self.actionButtonHeight, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(a.isCurrent ? AnyShapeStyle(Theme.gold) : AnyShapeStyle(Theme.panelDark.opacity(a.enabled ? 0.9 : 0.4))))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(a.enabled ? Theme.goldDim : Theme.goldDim.opacity(0.3), lineWidth: 1))
        }.disabled(!a.enabled && !keepTouchable)
        .modifier(ShortcutIfAny(key: controller.worldShortcutsVetoed ? nil : a.key))   // vetoed under a popup or another screen
        // Unciv UnitUpgradeMenu opens on a long press (right-click) of the Upgrade button.
        .highPriorityGesture(LongPressGesture(minimumDuration: UserSettings.longPressSeconds).onEnded { _ in a.longPress?() }, including: a.longPress == nil ? .subviews : .all)
    }
}

/// A keyboard shortcut only where the action has one, so the actions Unciv leaves unbound stay unbound.
private struct ShortcutIfAny: ViewModifier {
    let key: KeyEquivalent?
    func body(content: Content) -> some View {
        if let key { content.keyboardShortcut(key, modifiers: []) } else { content }
    }
}

