// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// MARK: - Unciv unit actions, notifications, city screen extras, zoom (WorldScreen pieces)
extension GameController {
    // Escort formation
    func startEscort() { guard !isProcessing, let u = selectedUnit else { return }; state.startEscorting(unitId: u.id); refresh(full: false) }
    func stopEscort() { guard !isProcessing, let u = selectedUnit else { return }; state.stopEscorting(unitId: u.id); refresh(full: false) }
    // Guard
    func guardSelected() { guard !isProcessing, let u = selectedUnit else { return }; Audio.shared.play("fortify"); state.setOrder(unitId: u.id, .guardPost); refresh() }
    // Repair (Unciv getRepairAction: `tile.queueImprovement(Constants.repair, turnsToBuild); unit.action = null`)
    func repairSelected() { guard !isProcessing, let u = selectedUnit else { return }; state.queueRepair(u.id); refresh() }
    // Stop movement / exploration / automation / escort (Unciv sets unit.action = null)
    func stopOrders() { guard !isProcessing, let u = selectedUnit else { return }; state.setOrder(unitId: u.id, .none); refresh(full: false) }
    /// Unciv StopAutomation: `unit.action = null; unit.automated = false`
    func stopAutomation() { guard !isProcessing, let u = selectedUnit else { return }; state.setOrder(unitId: u.id, .none); state.setAutomated(unitId: u.id, false); refresh(full: false) }
    /// Unciv ShowUnitDestination: `setCenterPosition(unit.getMovementDestination().position, true)` - at once, and the
    /// destination tile is selected (whatever stands there)
    func showUnitDestination() {
        guard let u = selectedUnit else { return }
        if case .moveTo(let t) = u.order { setCenterPosition(t, immediately: true) } else if case .connectRoad(let t) = u.order { setCenterPosition(t, immediately: true) }
        refresh(full: false)
    }
    // Gift unit
    func giftSelected() { guard !isProcessing, let u = selectedUnit else { return }; state.giftUnit(unitId: u.id); refresh() }
    // Transform (Unciv: the action itself is silent - its button's onActivation plays UnitActionType.Transform's Upgrade sound)
    func transformSelected(to name: String) { guard !isProcessing, let u = selectedUnit else { return }; state.transform(unitId: u.id, to: name); refresh(full: false) }
    // Hurry policy
    // Connect road: pick a target tile, then the worker walks the road path building as it goes.
    func connectRoad(to target: HexCoord) {
        guard !isProcessing, let u = selectedUnit, u.def.isWorker else { return }
        state.setOrder(unitId: u.id, .connectRoad(target))
        // OverlayButtonData.connectRoadToTargetTile: `automatedRoadConnectionPath = null; action = ConnectRoad; automated = true`,
        // then `UnitAutomation.automateUnitMoves(selectedUnit)` (the heal and run-away checks before the road step)
        if let i = state.unitIndex(u.id) { state.units[i].roadConnectionPath = [] }
        state.setAutomated(unitId: u.id)
        state.automateUnitMoves(u.id)
        refresh()
    }

    // MARK: notifications (Unciv Notification.execute: cycle through the actions)
    /// Unciv EmpireOverviewScreen.showOneTimeNotification: back to the map, the entry shown in the list once, its actions
    /// started from the first again. `inList`: the entry is one of the world list's own (this turn's, picked in the
    /// overview's notification tab) - not an earlier turn's, nor one made for the pick (getExploredResourcesNotification,
    /// the console's `tile find`), which Unciv's identity test never finds in the list
    func showOneTimeNotification(_ item: NotificationItem, inList: Bool) {
        setOneTimeNotification(item, inList: inList)
        notificationRoundRobin["\(state.turn)|\(item.index)|\(item.text)"] = 0
        executeNotification(item)
        if item.meta.actions.isEmpty { refresh(full: false) }   // GUI.resetToWorldScreen → setScreen: `newScreen.shouldUpdate = true`
    }
    func executeNotification(_ item: NotificationItem) {
        let actions = item.meta.actions
        guard !actions.isEmpty else { return }
        let key = "\(state.turn)|\(item.index)|\(item.text)"   // Unciv Notification.index belongs to the notification itself
        let idx = notificationRoundRobin[key, default: 0] % actions.count
        notificationRoundRobin[key] = idx + 1
        switch actions[idx] {
        case .location(let c): setCenterPosition(c, selectUnit: false)   // Unciv LocationAction: the tile selected, nothing on it
        case .city(let c): if let city = state.city(at: c), city.civId == state.playerId { selectedCityId = city.id; selectedUnitId = nil; showCity = true }
        case .tech(let t): techPickerCenterOn = t.isEmpty ? nil : t; showTech = true
        case .diplomacy(let name): diplomacyCiv = state.civs.first { $0.nation == name }?.id; showDiplomacy = true
        case .diplomacyTrade(let name):
            // Unciv DiplomacyAction.execute: trading with ourselves would have no other side, and neither a
            // city-state nor a civ we are at war with can be traded with, so those fall back to the leader screen.
            if let other = state.civs.first(where: { $0.nation == name }), other.id != state.playerId {
                diplomacyCiv = other.id
                if other.isCityState || state.player.isCityState || state.areAtWar(state.playerId, other.id) { showDiplomacy = true }
                else { openTrade(with: other.id) }
            }
        case .unit(let c, let id):
            // Unciv MapUnitAction: our unit with that id is shown where it stands now and selected; otherwise the saved
            // place, whatever stands there selected only when the action names no unit (`selectUnit = id == Constants.NO_ID`)
            if let u = state.unit(id), u.civId == state.playerId { setCenterPosition(u.coord, forceSelectUnit: id) } else { setCenterPosition(c, selectUnit: id == -1) }
        case .civilopedia(let link): civilopediaEntry = link.isEmpty ? nil : link; showCivilopedia = true
        case .overview(let page, let select): overviewPage = page.isEmpty ? nil : page; overviewSelect = select; showOverview = true
        case .policy(let name): policyHighlight = name.isEmpty ? nil : name; showPolicies = true
        case .espionage: showEspionage = true
        case .religion(let name): religionHighlight = name.isEmpty ? nil : name; overviewPage = "Religion"; overviewSelect = name; showOverview = true
        case .link(let url): if let u = URL(string: url) { UIApplication.shared.open(u) }
        case .promoteUnit(let name, let c, let id):
            // Unciv PromoteUnitAction: the PromotionPickerScreen for our unit with that id - without an id, our military
            // unit of that name on the tile - else nothing; the map and its selection are left alone
            let unit = id != -1 ? state.unit(id).flatMap { $0.civId == state.playerId ? $0 : nil }
                : state.units(at: c).first { !$0.def.isAir && $0.isMilitary }.flatMap { $0.name == name && $0.civId == state.playerId ? $0 : nil }
            if let u = unit { promotionUnitId = u.id; showPromotions = true }
        case .mayaLongCount: showMayaCalendar = true   // Unciv MayaLongCountAction opens the calendar popup
        }
        refresh(full: false)
    }

    // MARK: city screen extras (Unciv CitizenManagementTable / ConstructionInfoTable)
    func setCityFocus(_ name: String) { guard isMyTurn, let c = selectedCity, c.civId == state.playerId, !c.isPuppet else { return }; state.setCityFocus(cityId: c.id, name); refresh(full: false) }
    /// Unciv CityScreenTileTable.TileBuyMenu.buyRing: every tile of the ring until one cannot be bought, then Stat.Gold.purchaseSound
    func buyTilesInRing(_ ring: Int) { guard isMyTurn, let c = selectedCity, c.civId == state.playerId else { return }; state.buyTilesInRing(cityId: c.id, ring: ring); Audio.shared.play("coin"); refresh() }
    /// Unciv City.reassignPopulation(resetLocked = true): worked and locked tiles are dropped and everyone is
    /// reassigned, but a hand-placed specialist layout is left alone - the flag itself is never cleared.
    func resetCitizens() { guard isMyTurn, let c = selectedCity, c.civId == state.playerId, !c.isPuppet, let ci = state.cityIndex(c.id) else { return }; state.cities[ci].lockedTiles = []; state.assignWorkers(cityId: c.id, resetLocked: true, why: "GameController+Actions:5349"); refresh(full: false) }
    func toggleAvoidGrowth() { guard isMyTurn, let c = selectedCity, c.civId == state.playerId, !c.isPuppet else { return }; state.setAvoidGrowth(cityId: c.id, !c.avoidGrowth); refresh(full: false) }
    func sellBuilding(_ name: String) { guard isMyTurn, let c = selectedCity, c.civId == state.playerId, state.canSellBuilding(c, name) else { return }; state.sellBuilding(cityId: c.id, name); refresh(full: false) }   // the Coin sound belongs to the Sell button

    // MARK: free Great People (Unciv GreatPersonPickerScreen)
    /// Unciv GreatPeopleManager.chooseFreeGreatPerson: the unit is placed (nothing else - no selection); false without room
    @discardableResult
    func chooseFreeGreatPerson(_ name: String) -> Bool {
        guard !isProcessing else { return false }
        let placed = state.chooseFreeGreatPerson(state.playerId, name) != nil
        refresh()
        return placed
    }

    // MARK: rename (Unciv CityRenamePopup / UnitRenamePopup)
    func renameCity(_ name: String) { guard isMyTurn, let c = selectedCity, c.civId == state.playerId, let ci = state.cityIndex(c.id), !name.isEmpty else { return }; state.cities[ci].name = name; refresh() }
    /// Unciv UnitRenamePopup: the unit it was opened for - the selected one, or the overview's row (`unitId`)
    func renameUnit(_ name: String, unitId: Int? = nil) { guard !isProcessing, let u = unitId.flatMap({ state.unit($0) }) ?? selectedUnit, let ui = state.unitIndex(u.id) else { return }; state.units[ui].customName = (name.isEmpty || name == u.name) ? nil : name; refresh(full: false) }

    // MARK: battle table / city screen parts
    /// Unciv BattleTable.attack: air sweeps, air strikes and nukes fire from here too; the table stays while the attacker can still attack.
    /// `fromAttackButton`: the "Attack" button (onAttackButtonClicked), the only one that clears the undo checkpoints - the
    /// NUKE and Air Sweep buttons (simulateNuke / simulateAirsweep) have their own onClick without clearUndoCheckpoints.
    func attackBattleTarget(fromAttackButton: Bool = false) {
        guard !isProcessing, isMyTurn, !player.isSpectator, let u = selectedUnit, let t = battleTarget else { return }   // Unciv canChangeState
        // Unciv BattleTable: the table stays on the selected tile after the attack and shows again while a foreign combatant is there
        if u.def.isAir {
            // Unciv simulateAirsweep: onClick(attacker.getAttackSound()) { tryAirSweep }
            if sweepMode, state.canAirSweep(u, t) { sweepMode = false; Audio.shared.playAttack(u.def); state.airSweep(unitId: u.id, target: t, preparing: true); refresh(); return }
            guard state.airTargets(for: u).contains(t) else { return }
            if state.unitHasUnique(u, "Nuclear weapon of Strength []") {
                // Unciv BattleTable NUKE button: onClick(attacker.getAttackSound()) { tryNuke }, then the nukeCircle grows over the target tile group
                Audio.shared.playAttack(u.def)
                scene.nukeAnimation = t
                state.airStrike(unitId: u.id, target: t); refresh(); return
            }
            performAirStrike(u, t, clearsUndo: fromAttackButton)
            return
        }
        guard attackable.contains(t) else { return }
        performAttackFromTable(u, t, clearsUndo: fromAttackButton)   // a (modded) ground nuke's NUKE button does not clear them
    }
    func assignSpecialist(_ name: String) { guard isMyTurn, let c = selectedCity, c.civId == state.playerId, !c.isPuppet else { return }; state.tryAssignSpecialist(cityId: c.id, name); refresh(full: false) }
    func unassignSpecialist(_ name: String) { guard isMyTurn, let c = selectedCity, c.civId == state.playerId, !c.isPuppet else { return }; state.tryUnassignSpecialist(cityId: c.id, name); refresh(full: false) }
    func toggleManualSpecialists() { guard isMyTurn, let c = selectedCity, c.civId == state.playerId, !c.isPuppet else { return }; state.setManualSpecialists(cityId: c.id, !c.manualSpecialists); refresh(full: false) }
    /// Unciv CityStateDiplomacyTable.getCityStateDiplomacyTable: the table recomputes the city-state's ally as it is built
    func cityStateDiplomacyTableShown(_ csId: Int) {
        let before = state.ally(of: csId)
        state.cityStateDiplomacyTableShown(csId)
        if state.ally(of: csId) != before { refresh() }
    }
    /// Unciv CityScreen.page: cycle through our cities with the arrows.
    func cycleCity(_ delta: Int) {
        // Unciv CityView.getViewableCities: casusla bakilan bir sehirdeysek, casusu kurulu sehirler arasinda geziyoruz
        let cur0 = selectedCityId.flatMap { state.city($0) }
        let mine: [City] = (cur0?.civId ?? state.playerId) == state.playerId ? state.cities(of: state.playerId)
            : state.cities.filter { c in c.civId != state.playerId && state.player.spies.contains { $0.cityId == c.id && $0.alive && GameState.spySetUpActions.contains($0.action) } }
        guard let cur = selectedCityId, let i = mine.firstIndex(where: { $0.id == cur }), mine.count > 1 else { return }
        selectedCityId = mine[(i + delta + mine.count) % mine.count].id
        cityTile = nil
        // the new CityScreen's init and its updateAsync: `cityView.updateCityStats()` twice (CityScreen.kt:164, 567)
        if let id = selectedCityId { state.cityScreenOpened(id); state.updateCityStats(id, reason: "CityScreen.updateAsync") }
        refresh(full: false)
    }

    // MARK: events
    func chooseEvent(_ choice: EventChoiceDef, unitId: Int?) { guard !isProcessing else { return }; state.triggerChoice(choice, civId: state.playerId, unitId: unitId); refresh() }

    // MARK: zoom (Unciv ZoomButtonPair)
    func zoomIn() { scene.zoom(by: 0.8) }
    func zoomOut() { scene.zoom(by: 1.25) }
    func overlaysChanged() { scene.resetTiles(); refresh() }
}
