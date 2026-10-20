// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
extension GameState {
    enum EndTurnResult { case nextHuman, newTurn }

    private func archiveNotifications(_ i: Int) {
        // Unciv TurnManager.endTurn: `while (notificationsLog.size >= notificationsLogMaxTurns) notificationsLog.removeAt(0)`,
        // then this turn's entry only if it has notifications - a cap on entries, not a window of turns: a quiet turn
        // takes no slot, and the log is trimmed even when this turn adds nothing.
        while !civs[i].notificationLog.isEmpty && civs[i].notificationLog.count >= UserSettings.notificationsLogMaxTurns {
            civs[i].notificationLog.removeFirst()
        }
        if !civs[i].notifications.isEmpty {
            let items = civs[i].notificationItems
            civs[i].notificationLog.append(NotificationLogEntry(turn: turn, texts: items.map { $0.text }, meta: items.map { $0.meta }))
        }
    }

    /// Called when the current human presses "Next turn": Unciv GameInfo.nextTurn, the whole walk to the next living human.
    @discardableResult
    func endTurn(shouldGainTime: Bool = false) -> EndTurnResult {
        if let over = endTurnBegin(shouldGainTime: shouldGainTime) { return over }
        while true { if case .finished(let result) = endTurnStep() { return result } }
    }

    /// Unciv GameInfo.nextTurn, split so the world screen can show NextTurnProgress between the civs it walks:
    /// `endTurnBegin` ends the current human's turn (TurnManager.endTurn), then each `endTurnStep` plays the next
    /// civilization in the list, wraps the round, or starts the next living human's turn and finishes.
    /// Returns `.newTurn` without doing anything once the game is over. `shouldGainTime` is Unciv nextTurn's own
    /// parameter: true only from the world screen's Next turn (WorldScreen.nextTurn), false by default (a skipped turn).
    func endTurnBegin(shouldGainTime: Bool = false) -> EndTurnResult? {
        // (Unciv WorldScreen.nextTurn plays the turn on `originalGameInfo.clone()` after its setTransients(): that is
        // uncivNextTurnTransients, which GameController.endTurn runs first - the fresh Tile objects' isAdjacentToCoast
        // included. GameInfo.nextTurn itself clones nothing.)
        guard outcome == nil else { return .newTurn }
        let acting = currentHumanId
        // Unciv GameInfo.nextTurn: `if (player.isHuman() && player.isAlive())` the seconds since currentTurnStartTime
        // (Duration.toSeconds) join totalTurnTimeSeconds and turnsPlayedAsHuman++. (Our currentTurnStartTime reads 0
        // where Unciv's field default is the moment the game object was made - no time has passed then.)
        if let i = civIndex(acting), civs[i].isPlayer && civs[i].isAlive {
            let seconds = currentTurnStartTime > 0 ? Int(((Date().timeIntervalSince1970 * 1000 - currentTurnStartTime) / 1000).rounded(.towardZero)) : 0
            civs[i].totalTurnTimeSeconds += seconds
            civs[i].turnsPlayedAsHuman += 1
        }
        // Unciv GameInfo.nextTurn: `if (gameParameters.isOnlineMultiplayer) updateMinutesBeforeForceResign(player, shouldGainTime)`
        if settings.isOnline { updateMinutesBeforeForceResign(acting, shouldGainTime: shouldGainTime) }
        if isHotSeat {
            if let i = civIndex(acting) { archiveNotifications(i); civs[i].clearNotifications() }
            invalidateHappiness()
            processTurn(for: acting)
        } else {
            for i in civs.indices { if civs[i].isPlayer { archiveNotifications(i) }; civs[i].clearNotifications() }
            invalidateHappiness()
            processTurn(for: acting)
        }
        // Unciv setNextPlayer walks on from the human whose turn just ended
        turnWalkIndex = uncivTurnOrder().firstIndex(of: acting) ?? -1
        turnWalkWrapped = false
        return nil
    }

    /// Unciv GameInfo.nextTurn as Multiplayer.resignPlayer calls it, the current player having just become an AI:
    /// `player.isHuman() && player.isAlive()` and `if (player.isHuman()) { TurnManager.endTurn; setNextPlayer() }` are
    /// both passed over, updateMinutesBeforeForceResign still runs (shouldGainTime false), and the walk starts AT the
    /// resigned civ - it plays its turn through as an AI (startTurn, automateTurn, endTurn), then the walk goes on to
    /// the next living human as any walk does (the wrap, turns++ and the barbarians included).
    func nextTurnAfterResign(_ civId: Int) {
        guard outcome == nil else { return }
        if settings.isOnline { updateMinutesBeforeForceResign(civId, shouldGainTime: false) }
        turnWalkIndex = (uncivTurnOrder().firstIndex(of: civId) ?? 0) - 1
        turnWalkWrapped = false
        while true { if case .finished = endTurnStep() { return } }
    }

    /// Unciv GameInfo.civilizations in its own order, less the barbarians - Unciv's index 0, played here at the wrap:
    /// GameStarter.chooseCivilizations puts the spectators first ("ensure Spectators always first players"), then
    /// the majors in the order they were chosen, then the city-states. An imported save is in that order already;
    /// a game we started has its spectator after the majors and its barbarians last.
    func uncivTurnOrder() -> [Int] {
        let rest = civs.filter { !$0.isBarbarian }
        return (rest.filter { $0.isSpectator } + rest.filter { !$0.isSpectator }).map { $0.id }
    }

    /// diplomacyTurnDoneThisRound as the walk's position gives it, for a game whose file does not say: an Unciv save, or
    /// one of ours from before the set was saved. Unciv keeps no such set - each side's copy of a trade counts its own
    /// ends of turn (DiplomacyTurnManager.nextTurnTrades) - and a load goes on from `currentPlayer` in the same
    /// civilizations order. So they are the civilizations listed before the current player, back to where this round's
    /// walk began: the start of the list after the wrap (turns++ and the barbarians), or, in the game's first round
    /// (turns == 0), the player GameInfo.setTransients made current - `civilizations.first { it.isHuman() }`, online the
    /// first that is not a Spectator - before which nobody has played yet. Of those, the ones whose TurnManager.endTurn
    /// got past `if (civInfo.isDefeated() || civInfo.isSpectator()) return` to the diplomacy managers.
    func diplomacyTurnsDoneBeforeCurrentPlayer() -> Set<Int> {
        let order = uncivTurnOrder()
        guard let current = order.firstIndex(of: currentHumanId) else { return [] }
        var start = 0
        if uncivTurns == 0 {
            start = order.firstIndex { id in civ(id).map { $0.isPlayer && !(settings.isOnline && $0.isSpectator) } ?? false } ?? current
        }
        guard start < current else { return [] }
        return Set(order[start..<current].filter { id in civ(id).map { $0.isAlive && !$0.isSpectator } ?? false })
    }

    /// Unciv GameInfo.nextTurn's `while (player.isAI() || shouldAutoProcessHotseatPlayer() || shouldAutoProcessOnlinePlayer())`:
    /// an AI is played through, and so is a defeated human - unless every human is defeated and this is the first
    /// one - and, online, a spectator. Anyone else is a living human, and the walk stops there.
    func isAutoProcessedInTurnWalk(_ c: Civilization) -> Bool {
        if !c.isPlayer { return true }
        let anyHumanAlive = civs.contains { $0.isPlayer && $0.isAlive }   // Unciv `civilizations.any { it.isHuman() && it.isAlive() }`
        let firstHuman = uncivTurnOrder().first { civ($0)?.isPlayer == true }
        let defeated = !c.isAlive && (anyHumanAlive || firstHuman != c.id)
        if defeated && GameState.evlogOn { hbr("S12.defeatedHumanSkipped", c.id) }
        return settings.isOnline ? (c.isSpectator || defeated) : defeated
    }

    /// The civilizations the walk is going to play before it reaches a living human, as it stands now (for the
    /// progress bar only - the walk itself decides step by step, as Unciv's loop does).
    func turnWalkPreview() -> [Int] {
        guard let from = turnWalkIndex else { return [] }
        let order = uncivTurnOrder()
        guard !order.isEmpty else { return [] }
        var ids: [Int] = [], idx = from
        for _ in 0..<(order.count + 1) {
            idx += 1
            if idx >= order.count { idx = 0 }
            guard let c = civ(order[idx]), isAutoProcessedInTurnWalk(c) else { break }
            ids.append(c.id)
        }
        return ids
    }

    enum TurnWalkStep { case played(Int), wrapped, finished(EndTurnResult) }

    /// One step of Unciv GameInfo.nextTurn after the human's endTurn: `setNextPlayer()` - wrapping to the start of
    /// the list runs recordRankingStats and turns++, and the barbarians (Unciv's first civilization) play - then the
    /// next civilization is either played through (startTurn, automateTurn, endTurn) or, a living human, gets
    /// `currentTurnStartTime`, TurnManager.startTurn, notifyOfCloseEnemyUnits and notificationCountAtStartTurn.
    /// Ours played every human first (in hot-seat each handed straight to the next with no startTurn at all, which
    /// ran for all of them together at the end of the round) and every AI after them, before the wrap - so a civ
    /// listed before the human played a turn number early, before the barbarians, and a hot-seat human's cities
    /// finished their production before the human listed ahead of it had moved.
    func endTurnStep() -> TurnWalkStep {
        guard var idx = turnWalkIndex else { return .finished(.newTurn) }
        let order = uncivTurnOrder()
        idx += 1
        if idx >= order.count {
            // Unciv GameInfo.nextTurn walks on to the next living human whoever has won meanwhile - the round is wrapped
            // (turns++, the barbarians) after a victory too, and the victory screen comes up at the human's turn.
            // A second wrap means no living human is left to stop at: Unciv's loop would never end, ours stops.
            guard !turnWalkWrapped else { turnWalkIndex = nil; turnWalkWrapped = false; return .finished(.newTurn) }
            endTurnWrap()
            turnWalkIndex = -1
            turnWalkWrapped = true
            return .wrapped
        }
        turnWalkIndex = idx
        guard let c = civ(order[idx]) else { return .played(order[idx]) }
        if isAutoProcessedInTurnWalk(c) {
            if !c.isPlayer { endTurnAI(c.id); return .played(c.id) }
            // A defeated hot-seat human (or an online spectator): TurnManager.startTurn runs whole, automateTurn
            // returns for a defeated civ, and endTurn files its notifications before its own isDefeated/isSpectator return.
            invalidateHappiness()
            startTurnProcessing(for: c.id, evenIfDefeated: true)
            if let i = civIndex(c.id) { archiveNotifications(i); civs[i].clearNotifications() }
            return .played(c.id)
        }
        // "We found a human player, so we are making them current"
        turnWalkIndex = nil
        let wrapped = turnWalkWrapped
        turnWalkWrapped = false
        startHumanTurn(c.id)
        if wrapped { checkVictory() }
        return .finished(wrapped ? .newTurn : .nextHuman)
    }

    /// Unciv GameInfo.nextTurn after the walk: `currentTurnStartTime`, `currentPlayer`, TurnManager(player).startTurn,
    /// notifyOfCloseEnemyUnits, and notificationCountAtStartTurn.
    private func startHumanTurn(_ civId: Int) {
        currentHumanIndex = humans.firstIndex { $0.id == civId } ?? 0
        currentTurnStartTime = Date().timeIntervalSince1970 * 1000   // Unciv GameInfo.currentTurnStartTime
        invalidateHappiness()
        startTurnProcessing(for: civId, evenIfDefeated: true)   // Unciv calls startTurn for whoever the walk stopped at
        // (the automated units' turn-start moves run inside startTurnProcessing, right after the units' own startTurn)
        // no updateViewableTiles of its own: startTurn's (TurnManager.kt:63) is the one, then notifyOfCloseEnemyUnits
        notifyOfCloseEnemyUnits(civId)
        // Unciv GameInfo.nextTurn: notificationCountAtStartTurn, right after notifyOfCloseEnemyUnits
        if let ci = civIndex(civId) { civs[ci].notificationCountAtStartTurn = civs[ci].notifications.count }
    }

    func endTurnAI(_ civId: Int) {
        defer { if GameState.evlogOn { EvLog.flushProduction() } }   // EVLOG: no PROD_SET left over past the civ's turn
        guard let c = civ(civId), !c.isPlayer else { return }
        // Unciv GameInfo.nextTurn plays a defeated AI civ too: TurnManager.startTurn runs whole (updateCivResources,
        // updateStatsForNextTurn, the flags ...), automateTurn returns at `if (civInfo.isDefeated())` and endTurn
        // stops at its own isDefeated check. Ours skipped the dead civ, so the resources its ended trades had
        // supplied stayed in its stored supply (settled t=179: Byzantium's Cotton/Wine after losing Constantinople).
        if !c.isAlive {
            invalidateHappiness()
            startTurnProcessing(for: civId, evenIfDefeated: true)
            return
        }
        invalidateHappiness()
        startTurnProcessing(for: civId)   // Unciv TurnManager.startTurn runs before the civ's automation
        let t0 = Date()
        AI(state: self, civId: civId).takeTurn()
        turnAITime += Date().timeIntervalSince(t0)
        invalidateHappiness()
        // Unciv GameInfo.nextTurn, between automateTurn and endTurn: `if (worldScreen.autoPlay.isAutoPlaying() &&
        // player.victoryManager.hasWon() && !oneMoreTurnMode) worldScreen.autoPlay.stopAutoPlay()` - the civ that has won
        // stops the multi-turn AutoPlay, and the rest of the walk is played with it off. VictoryManager.hasWon() is
        // `getVictoryTypeAchieved() != null` (VictoryManager.kt:165), what the civ achieves now - the spaceship part its
        // automation has just added -, not the recorded victoryData, which only its endTurn writes after this check
        if autoPlayGoesOn && !oneMoreTurnMode, let c = civ(civId), victoryTypeAchieved(c) != nil { autoPlayGoesOn = false }
        // Unciv TurnManager.endTurn opens with `if (settings.citiesAutoBombardAtEndOfTurn) NextTurnAutomation.automateCityBombardment(civInfo)`
        // - for every civ GameInfo.nextTurn walks, not only the human: an AI city gets a second shot at whatever its own
        // units revealed or drew into range after its automateCivMoves bombard. Ours ran it for the human only.
        if UserSettings.citiesAutoBombardAtEndOfTurn { automateCityBombardment(civId) }
        let t1 = Date()
        processTurn(for: civId)
        turnProcessTime += Date().timeIntervalSince(t1)
    }

    /// Unciv setNextPlayer when the index wraps to 0: recordRankingStats() and turns++, then civilizations[0] - the
    /// barbarians - plays.
    private func endTurnWrap() {
        let aiTime = turnAITime, processTime = turnProcessTime
        invalidateHappiness()
        let t2 = Date()
        // Unciv GameInfo.nextTurn → setNextPlayer: when the player index wraps to 0 it runs recordRankingStats()
        // (which resets every major's military-might cache and fills it again for the Force ranking) and turns++,
        // and only THEN plays civilizations[0] - the barbarians, first in the list of every game. Ours recorded
        // after the barbarians had moved, so the majors' Force cache held the post-barbarian value where Unciv's
        // holds the pre-barbarian one until each major's own endTurn resets it. (Our turn counter still moves after
        // the barbarians; barbarianPhase makes the rolls read Unciv's incremented `turns` meanwhile.)
        recordRankingStats()
        if let b = barbarianCivId { threatManagerCache[b] = nil }   // Unciv: the barbarians' own TurnManager.startTurn clears it too
        barbarianPhase = true; barbarianTurn(); barbarianPhase = false
        if let b = barbarianCivId { endTurnTemporaryUniques(civId: b); resetMilitaryMightCache(b) }   // Unciv: the barbarians' own TurnManager.endTurn
        // The city-state great-person gifts are counted down in each major's startTurnFlags now, as in Unciv.
        dealsTurn()
        invalidateHappiness()
        recordTileHistoryChanges()
        if epochsDebug && (turn % 10 == 0 || aiTime + processTime > 5) {
            let parts = AI.profile.sorted { $0.value > $1.value }.map { "\($0.key)=\(Int($0.value * 1000))" }.joined(separator: " ")
            print("PROFILE t\(turn) ai=\(Int(aiTime * 1000))ms process=\(Int(processTime * 1000))ms misc=\(Int(Date().timeIntervalSince(t2) * 1000))ms units=\(units.count) | \(parts)")
        }
        if epochsDebug { AI.profile.removeAll() }   // AI.timed fills it only with --debug; a UI turn runs on its own thread
        turnAITime = 0; turnProcessTime = 0   // the PROFILE line covers one full round of AI turns
        diplomacyTurnDoneThisRound.removeAll()
        vpLeagueTurn()   // VP: VP/VPLeague.swift (the World Congress)
        vpUpdateWarWeariness()   // VP: VP/VPWar.swift
        vpSpreadFranchises()   // VP: VP/VPCorporations.swift
        vpUpdateMedians()   // VP: CvGame::DoUpdateGlobalMedians, once a round (no-op without the VP mod)
        turn += 1
    }

    /// Unciv `for (unit in civInfo.units.getCivUnits()) unit.doAction()` (TurnManager.startTurn, CivView.tryAutomateAllUnits):
    /// the civ's unit list as it stands when the walk starts, each unit read as it is when its turn in the loop comes.
    func continueOrders(for civId: Int) {
        let helper = AI(state: self, civId: civId)
        for id in units.filter({ $0.civId == civId }).map({ $0.id }) {
            guard unit(id) != nil else { continue }
            doAction(id, helper: helper)
        }
    }

    /// Unciv MapUnit.doAction: nothing without an action or the automated flag, nor without movement, nor while the escort
    /// partner has none; an enemy in walking distance stops a move order, and only an explorer or an automated unit goes
    /// on ("have fleeing code"); a move order heads on (doMoveAction, which calls this again while movement is left);
    /// then `if (isAutomated()) automateUnitMoves` (a road-connecting worker is automated: its road step) and `if
    /// (isExploring()) automatedExplore` - each read as the unit stands by then. `automated` is a flag of its own, so an
    /// automated unit the player fortified, put to sleep or moved is automated here all the same.
    func doAction(_ unitId: Int, helper: AI) {
        guard let u = unit(unitId) else { return }
        guard u.order != .none || u.isAutomated else { return }
        guard u.hasMovement else { return }   // "We've already done stuff this turn, and can't do any more stuff"
        if isEscorting(u), let e = otherEscortUnit(u), !e.hasMovement { return }
        if case .moveTo = u.order { doMoveAction(unitId); return }
        guard let v = unit(unitId) else { return }
        if v.isAutomated {
            // `if (isAutomated()) UnitAutomation.automateUnitMoves(this)` for a road-connecting worker too: the terrain heal and
            // CivilianUnitAutomation's tryRunAwayIfNeccessary come before its isAutomatingRoadConnection road step
            automateUnitMoves(unitId)
        }
        if let w = unit(unitId), w.order == .explore { helper.explore(w) }
    }

    /// Unciv TurnManager.startTurn: what the last turn paid for is finished now, before the civ moves —
    /// cities first (CityTurnManager.startTurn → constructIfEnough), then the great person and the prophet the points bought.
    func startTurnProcessing(for civId: Int, evenIfDefeated: Bool = false) {
        guard let ci = civIndex(civId), civs[ci].isAlive || evenIfDefeated, !civs[ci].isBarbarian else { return }
        if civs[ci].isSpectator { return }   // Unciv TurnManager.startTurn: `if (civInfo.isSpectator()) return`
        // Unciv marks every viewable tile explored from updateViewableTiles, for every civ. Ours only did it for
        // humans, so an AI's explored set lagged behind what it could actually see - it never counted what its
        // cities saw. That leaks into the explore automation, which scores a tile by how much unexplored land is
        // around it: our scouts read the same tiles as more unknown than Unciv did and walked somewhere else.
        // Unciv TurnManager.startTurn, in its order: updateResearchProgress, updateCivResources,
        // civConstructions.startTurn, updateStatsForNextTurn, the great people, updateViewableTiles,
        // updateCitiesConnectedToCapital, startTurnFlags, and only then the cities and the units.
        // Ours ran the units before the cities and the connections after the stats that read them.
        // Unciv TurnManager.startTurn, step by step:
        // hasSoldBuildingThisTurn reset, updateResearchProgress, updateCivResources, the stockpiled resources,
        // civConstructions.startTurn, updateStatsForNextTurn, the gold-to-science slider, the great people and
        // religionManager.startTurn and the Maya long count (only with cities), updateViewableTiles,
        // updateCitiesConnectedToCapital, startTurnFlags, updateRevolts, the civ's TriggerUponTurnStart - and
        // only then the cities, the units, and the promotion notifications.
        // Ours ran the revolts, the Maya calendar, the stockpiles, the slider and every "upon turn start"
        // trigger at the END of the civ's turn, and the building-sale reset inside the end-of-turn city pass.
        for i in cities.indices where cities[i].civId == civId { cities[i].hasSoldBuildingThisTurn = false }
        threatManagerCache[civId] = nil   // Unciv TurnManager.startTurn:32 `civInfo.threatManager.clear()`
        // Unciv: `if (civInfo.cities.isNotEmpty() && ruleset.technologies.isNotEmpty()) tech.updateResearchProgress()`
        if !cities(of: civId).isEmpty && !rs.techs.isEmpty { updateResearchProgress(civId: civId) }
        updateCivResources(civId)   // Unciv TurnManager.startTurn:37 - rebuilds the city-state bonus list
        // Unciv: `for (r in civInfo.getCivResourceSupply().filter { it.resource.isStockpiled }) gainStockpiledResource`
        // - the summarized supply updateCivResources has just stored; city-wide ones go to the city (none here).
        if rs.resources.values.contains(where: { $0.isStockpiled && !$0.isCityWide }) {
            let supply = civResourceSupply(civId)
            for r in rs.resourcesInOrder where r.isStockpiled && !r.isCityWide { if let n = supply[r.name], n != 0 { civs[ci].resourceStockpiles[r.name, default: 0] += n } }
            invalidateHappiness(civId)
        }
        tryAddFreeBuildings(civId)             // Unciv TurnManager.startTurn → CivConstructions.startTurn → tryAddFreeBuildings
        // Unciv CivConstructions.addFreeBuildings: "Automatically built in all cities where it is buildable" (mods only)
        let autoBuildings = rs.buildings.values.filter { $0.uniques.contains("Automatically built in all cities where it is buildable") }
        if !autoBuildings.isEmpty {
            for c in cities(of: civId) {
                let buildable = Set(buildableBuildings(for: c).map { $0.name })
                for b in autoBuildings where buildable.contains(b.name) { if let idx = cityIndex(c.id), !cities[idx].buildings.contains(b.name) { cities[idx].buildings.append(b.name) } }
            }
        }
        civs[ci].attacksSinceTurnStart.removeAll()   // Unciv TurnManager.startTurn: `civInfo.attacksSinceTurnStart.clear()`, after civConstructions.startTurn
        updateStatsForNextTurn(civId)   // Unciv TurnManager.startTurn: for things that change when the turn passes
        // Unciv NextTurnAutomation.automateGoldToSciencePercentage: after updateStatsForNextTurn, before the cities (AI, mod option only)
        if !civs[ci].isPlayer, rs.modOptionUniques.contains(where: { $0.pattern == "Can convert gold to science with sliders" }), let era = rs.era(named: civs[ci].eraName) {
            let projected = civs[ci].gold + Double(Int(civs[ci].statsForNextTurn?.gold ?? netGoldPerTurn(civId)))   // Unciv statsForNextTurn.gold.toInt()
            let poor = Double(era.baseUnitBuyCost), rich = Double(era.startingGold * 10) + Double(cities(of: civId).count * 2) * poor
            civs[ci].goldPercentConvertedToScience = civs[ci].gold <= 0 || projected <= poor ? 0 : min(0.8, (projected - poor) * 0.8 / max(1, rich))
        }
        // Unciv TurnManager.startTurn, in this order: `updateCivResources()` (37), `updateStatsForNextTurn()`
        // (43), then `updateViewableTiles()` (63) and `updateCitiesConnectedToCapital()` (64), and only then
        // the city loop. The order of these two is the whole point: the happiness FIELD is computed BEFORE
        // the connections are refreshed, so the first city to reassign its citizens still sees last turn's
        // happiness, and each city's own `cityStats.update()` carries the new value to the next one.
        // Measured on `settled` turn 72, where Satsuma connects: the reference ranks Tokyo's tiles at
        // happy=-1 and Satsuma's at happy=0, in the same turn. We ran the connection at the END of the turn
        // and read -1 for both; running it before the stats read 0 for both. Here, it reads what Unciv reads.
        // Unciv TurnManager.startTurn: greatPeople.getNewGreatPerson() and religionManager.startTurn() run
        // BEFORE `for (city in civInfo.cities) CityTurnManager(city).startTurn()`, so a great person takes the
        // city-centre slot ahead of the unit that finishes construction this turn, not after it.
        // All three sit inside `if (civInfo.cities.isNotEmpty())`.
        if !cities(of: civId).isEmpty {
            spawnGreatPeople(civId)
            generateProphet(for: civId)
            mayaTurnStart(civId)   // Unciv: `if (civInfo.isLongCountActive()) MayaCalendar.startTurnForMaya(civInfo)`
        }
        // Unciv's updateViewableTiles marks every viewable tile explored, for every civ, and runs
        // discoverNaturalWonders (at the end of updateExploration) - so a wonder a city or a grown border brought
        // into view counts even if no unit went near it.
        updateExploration(for: civId)
        let tConn = Date()
        updateCitiesConnectedToCapital(civId)
        if epochsDebug { AI.profile["p.connect", default: 0] += Date().timeIntervalSince(tConn) }
        startTurnFlags(civId: civId)           // Unciv TurnManager.startTurnFlags (+ handleDiplomaticVictoryFlags)
        updateRevolts(civId)                   // Unciv TurnManager.updateRevolts, right after the flags
        // Unciv TurnManager.startTurn: `civInfo.forEachTriggeredUnique(TriggerUponTurnStart, ignoreCities = true)`
        do {
            let isTurnStart: (Unique) -> Bool = { $0.pattern == "upon turn start" }
            let civPool = civTriggerPool(civId, includeCities: false).filter { $0.conditionals.contains(where: isTurnStart) }
            if !civPool.isEmpty { _ = triggerUniques(civPool.map { $0.withoutConditionals(where: isTurnStart) }, civId: civId, cityId: nil, unitId: nil, triggerText: nil) }
        }
        // Unciv CreatesOneImprovement: whatever the city is building claims its tile for as long as it is building it
        for c in cities(of: civId) {
            guard let idx = cityIndex(c.id) else { continue }
            let building: String? = { if case .building(let n)? = c.currentProduction { return n }; return nil }()
            let claim = building.flatMap { rs.buildings[$0]?.uniqueObjects.first { $0.pattern == "Creates a [] improvement on a specific tile" } }
            if let claim {
                if cities[idx].reservedImprovementTile == nil {
                    cities[idx].reservedImprovementTile = tileForCreatedImprovement(c, claim.param(0))
                    cities[idx].reservedImprovement = claim.param(0)
                }
            } else if cities[idx].reservedImprovementTile != nil {
                cities[idx].reservedImprovementTile = nil; cities[idx].reservedImprovement = ""
            }
        }
        // Unciv `for (city in civInfo.cities) CityTurnManager(city).startTurn()` - each city finishes its
        // construction, picks the next one AND reassigns its citizens before the NEXT city starts. We ran two
        // passes over the cities instead, all the constructions and then all the reassignments, so a later
        // city decided against an earlier city's stale production. Measured on `fresh` at turn 42: Unciv's
        // empire production average was 8.20 when Paris decided and 10.23 when Lyon did, because Paris's and
        // Orleans's citizens had moved in between; ours was 8.08 for both, and Lyon - 8.75 of production -
        // read itself as an above-average city, took the military option Unciv never offered it, and built a
        // Warrior. The interleaving is the rule, not an implementation detail.
        // Unciv CityTurnManager.startTurn: the citizens are reassigned here, at the start of the turn and BEFORE
        // the civ's automation moves - Automation.rankStatsForCityWork reads the current construction
        // (canConvertFoodToProduction), so doing it after the AI had already queued this turn's Settler made the
        // city work the Settler's tiles a whole turn early. constructIfEnough runs first, as it does in Unciv.
        // Unciv CityTurnManager.startTurn opens with the city-wide stockpiled resources the city generates and
        // `city.getTriggeredUniques(TriggerUponTurnStart, includeCivUniques = false)`; both now run inside
        // cityStartTurn, at their place in the city's own startTurn.
        for city in cities(of: civId) {
            cityStartTurn(cityId: city.id, civId: civId)   // Unciv CityTurnManager(city).startTurn()
        }
        // Unciv TurnManager.startTurn: `for (unit in civInfo.units.getCivUnits()) UnitTurnManager(unit).startTurn()`
        // comes AFTER the city loop, not before it. A unit gets its movement back, its counters cleared and its
        // status timers advanced only once every city has finished reassigning its citizens. Each unit does the
        // whole of UnitTurnManager.startTurn before the next one starts (UnitTurnManager.swift).
        for id in units.filter({ $0.civId == civId }).map({ $0.id }) { unitStartTurn(id) }
        // Unciv TurnManager.startTurn: `if (civInfo.playerType == PlayerType.Human && settings.automatedUnitsMoveOnTurnStart)
        // { hasMovedAutomatedUnits = true; for (unit in getCivUnits()) unit.doAction() }` - right after the units' startTurn and
        // BEFORE the trade requests, the "can be promoted" notifications and updateWinningCiv. The setting ships OFF: with it
        // off the Next-turn button becomes "Move automated units" and the player presses it. Ours moved them in
        // startHumanTurn, after this function had returned, so a unit that reached promotion XP on the way was announced a
        // turn late. Under --autoplay every civ is played by the AI (playerType AI), the player's included; Unciv's AutoPlay
        // leaves the playerType alone, so it does not move them here.
        if let cj = civIndex(civId), civs[cj].isPlayer, epochsAutoplay || UserSettings.automatedUnitsMoveOnTurnStart {
            if GameState.evlogOn && !civs[cj].isSpectator { hbr("S1.moveOnTurnStart", civId) }
            continueOrders(for: civId)
        }
        removeUntenableTradeRequests(civId)    // Unciv TurnManager.startTurn: requests one side can no longer supply are withdrawn
        notifyPromotableUnits(civId)           // Unciv TurnManager.startTurn: after the units and the trade requests
        checkVictory(winningCivOnly: civId)    // Unciv TurnManager.startTurn → updateWinningCiv: this civ only
    }

    /// Unciv TurnManager.startTurnFlags: every civ flag in the flag map's own order. The city-state
    /// great-person gift has its own branch (a draw from "TurnManager.startTurnFlags" over the allied
    /// city-states in getKnownCivs() order); every other flag counts down to 0, and at 0 the revolt spawns or the
    /// city-state holds its elections - a flag left at 0 fires again next turn until something removes it.
    /// Then handleDiplomaticVictoryFlags.
    /// Ours counted the gift down once per game turn, for every major together, after the last civ had moved -
    /// a turn number lower in the seed than Unciv's and before the allies had changed hands in that round - and
    /// seeded the election timers here, at the first civ's turn start, where Unciv seeds them in the
    /// city-state's own endTurn.
    func startTurnFlags(civId: Int) {
        guard let i = civIndex(civId) else { return }
        guard !civs[i].civFlags.isEmpty else { return }
        // `flagsCountdown.keys.toList()` walks a java.util.HashMap<String, Int>: bucket by bucket.
        var capacity = 16
        while civs[i].civFlags.count > capacity * 3 / 4 { capacity <<= 1 }
        let order = civs[i].civFlags.keys.sorted { a, b in
            let ba = javaBucket(a, capacity: capacity), bb = javaBucket(b, capacity: capacity)
            return ba != bb ? ba < bb : a < b
        }
        for flag in order {
            guard let ci = civIndex(civId), civs[ci].civFlags[flag] != nil else { continue }   // in case a flag was removed while iterating
            if flag == "CityStateGreatPersonGift" {
                var rng = stateBasedRandom("TurnManager.startTurnFlags", civId: civId)
                let cityStateAllies = knownCivs(civId).filter { $0.isCityState && ally(of: $0.id) == civId }
                let givingCityState = rng.pick(cityStateAllies.filter { !cities(of: $0.id).isEmpty })
                if !cityStateAllies.isEmpty { civs[ci].civFlags[flag]! -= 1 }
                if let countdown = civs[ci].civFlags[flag], countdown < min(cityStateAllies.count, 10), !cities(of: civId).isEmpty, let giver = givingCityState {
                    giveGreatPersonToPatron(cityState: giver.id, patron: civId)
                    if let cj = civIndex(civId) { civs[cj].civFlags[flag] = turnsForGreatPersonFromCityState(civId) }
                }
                continue
            }
            if civs[ci].civFlags[flag]! > 0 { civs[ci].civFlags[flag]! -= 1 }
            if civs[ci].civFlags[flag] != 0 { continue }
            switch flag {
            case "RevoltSpawning": doRevoltSpawn(civId)
            case "TurnsTillCityStateElection": holdElections(cityState: civId)
            default: break
            }
        }
        if let ci = civIndex(civId) { handleDiplomaticVictoryFlags(civIndex: ci) }
    }

    /// Yields, growth, production, science, culture, policies, golden ages, healing and worker progress for one civ.
    func processTurn(for civId: Int) {
        defer { if GameState.evlogOn { EvLog.flushProduction() } }   // EVLOG: no PROD_SET left over past the civ's turn
        guard let ci = civIndex(civId), civs[ci].isAlive else { return }
        // Unciv TurnManager.endTurn archives the notifications and then `if (civInfo.isDefeated() ||
        // civInfo.isSpectator()) return` - a spectator earns no gold, culture or golden age points. Ours ran the
        // whole turn for it and told it "You have entered a Golden Age!" (fresh turn 34).
        if civs[ci].isSpectator { return }
        invalidateHappiness(civId)
        // Unciv TurnManager.endTurn: `civInfo.forEachTriggeredUnique(TriggerUponTurnEnd, ignoreCities = true)` first -
        // the nation, founder beliefs, policies, techs, era and global uniques, not the cities' buildings (those fire
        // from each city's own CityTurnManager.endTurn). "Upon ending a turn in a [] tile" is the unit's own, fired in
        // UnitTurnManager.endTurn; ours fired it here a second time.
        do {
            let isTurnEnd: (Unique) -> Bool = { $0.pattern == "upon turn end" }
            let civPool = civTriggerPool(civId, includeCities: false).filter { $0.conditionals.contains(where: isTurnEnd) }
            if !civPool.isEmpty { _ = triggerUniques(civPool.map { $0.withoutConditionals(where: isTurnEnd) }, civId: civId, cityId: nil, unitId: nil, triggerText: nil) }
        }

        // Unciv TurnManager.endTurn reads the empire's stats ONCE, from the stored `statsForNextTurn`, and
        // spends them - culture into policies, gold into the treasury, science into research, faith into
        // religion - BEFORE any city takes its turn. We accumulated the same four numbers while walking the
        // cities and spent them afterwards. That is not only a different number (the stored sum is sometimes
        // deliberately staler than a fresh walk, and Unciv reads the stored one): it is a different ORDER.
        // Measured on t_45, Kyoto's fifth border expansion: Unciv expanded with `techs=8 iron=true` and took
        // the Desert/Iron tile (a strategic resource is worth -105 in rankTileForExpansion); ours expanded
        // with `techs=7 iron=false`, scored the same tile 199 instead of 93, and took a Grassland/Cattle tile
        // that Byzantium's Adrianople was about to claim - which cost Adrianople a citizen for the rest of
        // the game.
        updateStatsForNextTurn(civId)
        var nextTurnStats = civs[ci].statsForNextTurn ?? Stats()
        let civU = civUniques(civId)
        // Unciv TurnManager.endTurn: `policies.endTurn(nextTurnStats.culture.toInt())`, then the contests total
        civs[ci].totalCulture += nextTurnStats.culture
        policyEndTurn(civId: civId, culture: Int(nextTurnStats.culture))
        civs[ci].totalCultureForContests += Int(nextTurnStats.culture)
        if civs[ci].isCityState {
            // Unciv: `civInfo.questManager.endTurn()` here - after the culture, before the disbanding and the gold.
            // Unciv DiplomacyTurnManager.nextTurnCityStateInfluence runs from the CITY-STATE's own endTurn, and
            // setInfluence updates the ally the moment it moves; the quests go first, inside the same city-state
            // turn. We ran them for every city-state once the whole turn was over, so a quest's influence arrived
            // AFTER that turn's decay had already run and skipped the decay for a turn. Measured on `fresh`:
            // Persia's influence with Ragusa jumped 10 -> 45 at turn 47 where Unciv's read 43.5, stayed exactly one
            // decay step ahead for sixteen turns, kept the alliance a turn longer, and Persepolis ate a Maritime
            // ally's food at turn 63 that Unciv's no longer had.
            questsTurn(only: civId)
            // Unciv: with espionage, a city-state without an election timer gets a random one, in its own endTurn
            if espionageEnabled, let cj = civIndex(civId), civs[cj].civFlags["TurnsTillCityStateElection"] == nil {
                // Unciv TurnManager.kt:296: `civInfo.state.stateBasedRandom("TurnManager.endTurn(Espianage)")` (Unciv's own typo)
                var g = stateBasedRandom("TurnManager.endTurn(Espianage)", civId: civId)
                civs[cj].civFlags["TurnsTillCityStateElection"] = g.nextInt(below: rs.constants.cityStateElectionTurns + 1)
            }
        }
        // Unciv adds statsForNextTurn.gold whole: the "Trade" row IS the gold-per-turn deals, paid here in each
        // side's own turn. Settling them in dealsTurn for everyone at once paid a deal struck after the receiver's
        // income in that same turn (settled turn 110: Byzantium's 23 a turn reached Japan one turn early).
        // Unciv TurnManager: disband military units while gold <= -200 and the deficit persists (units in our
        // territory and least experienced first). Unciv re-reads statsForNextTurn after each disband, and so
        // do we - disband() refreshes the field through UnitManager.removeUnit.
        while civs[ci].gold <= -200 && Int(nextTurnStats.gold) < 0 {
            // Kotlin `sortedWith(compareByDescending { owner == civ }.thenBy { valueOfPromotionsAndXp })` is STABLE:
            // two units tied on both keys stay in the civ's unit order. Swift's sorted(by:) is not.
            let candidates = units(of: civId).filter { $0.isMilitary }.enumerated().sorted { ea, eb in
                let a = ea.element, b = eb.element
                let ai = map[a.coord]?.ownerCivId == civId, bi = map[b.coord]?.ownerCivId == civId
                if ai != bi { return ai }
                let va = valueOfPromotionsAndXp(a), vb = valueOfPromotionsAndXp(b)
                if va != vb { return va < vb }   // Unciv valueOfPromotionsAndXp
                return ea.offset < eb.offset
            }.map { $0.element }
            if ProcessInfo.processInfo.environment["DISBQ"] != nil {
                print("DISBE t=\(uncivTurns) \(civs[ci].nation) " + units(of: civId).filter { $0.isMilitary }.map { u in let p = uncivPosition(u.coord); return "\(u.name)@\(p.x),\(p.y):\(map[u.coord]?.ownerCivId == civId):\(valueOfPromotionsAndXp(u)):xp\(u.xp)n\(u.numberOfPromotions ?? -1)" }.joined(separator: " "))
            }
            guard let victim = candidates.first else { break }
            disband(unitId: victim.id)
            // Unciv: `unitName = unitToDisband.shortDisplayName()` ("[instanceName]" or "[name]", brackets included) is
            // both the text's and the first icon's, beside NotificationIcon.Death, and there is no location
            let unitName = victim.shortDisplayName
            notify(civId, "Cannot provide unit upkeep for \(unitName) - unit has been disbanded!", category: .Units, icons: [unitName, "Death"])
            nextTurnStats = civs[ci].statsForNextTurn ?? Stats()
        }
        // Unciv Civilization.gold is an integer and TurnManager adds nextTurnStats.gold.toInt(), so the fractional part
        // of a turn's income (or of its loss) is dropped rather than carried forward and compounded over the game.
        civs[ci].gold += Double(Int(nextTurnStats.gold))
        goldTrace(civId, Double(Int(nextTurnStats.gold)), caller: "endTurnIncome")
        if ProcessInfo.processInfo.environment["GOLDCITY"] == civs[ci].nation {
            print("GOLDCITYE t=\(turn) " + cities(of: civId).map { "\($0.name):\(currentCityStats($0.id).total.gold - Double(computeStats(for: $0).maintenance))" }.joined(separator: ",") + " rows=" + statMapForNextTurn(civId).map { "\($0.0):\($0.1.gold)" }.joined(separator: ",") + " next=\(nextTurnStats.gold)")
        }

        // Unciv TurnManager.endTurn → TechManager.endTurn(nextTurnStats.science.toInt()), with cities and techs.
        // The treasury deficit that costs science is a row of the stat map ("Treasury deficit"), so it is
        // already inside nextTurnStats - Unciv reads the same sum.
        if !cities(of: civId).isEmpty && !rs.techs.isEmpty {
            techEndTurn(civId: civId, scienceForNewTurn: Int(nextTurnStats.science), sciencePerTurn: nextTurnStats.science)
        }

        // Unciv TurnManager.endTurn: science, then faith, then espionage, then the great-person points
        religionTurn(for: civId, faithIncome: nextTurnStats.faith)
        espionageTurn(for: civId)
        if civs[ci].isMajor { accumulateGreatPeople(civId) }   // Unciv: `if (civInfo.isMajorCiv()) greatPeople.addGreatPersonPoints()`
        let tCities = Date()
        // Unciv TurnManager: "we need to run cities being razed first" so their tiles are released before the
        // surviving cities compute stats and expand borders.
        // Unciv `civInfo.cities.sortedByDescending { it.isBeingRazed }` is STABLE: the cities that are not being
        // razed keep the civ's own order. Swift's sorted(by:) is not, and with no city being razed the
        // comparator is false for every pair - so the loop could run the cities in any order at all. That order
        // decides which city sees a border grown by another city this turn: measured on `settled` turn 48,
        // Osaka banked its food before the luxury a sister city's expansion had just brought in, and did not grow.
        let razingFirst = cities(of: civId).filter { $0.razing } + cities(of: civId).filter { !$0.razing }
        for city in razingFirst { cityEndTurn(cityId: city.id, civId: civId) }   // Unciv CityTurnManager(city).endTurn()
        if epochsDebug { AI.profile["p.cities", default: 0] += Date().timeIntervalSince(tCities) }
        religionPressureTurn(for: civId)   // the inquisitor flags; the pressure itself runs per city in the loop above

        endTurnTemporaryUniques(civId: civId)   // Unciv TurnManager.endTurn: civInfo.temporaryUniques.endTurn(), after the cities
        // Unciv TurnManager.endTurn: `goldenAges.endTurn(civInfo.getHappiness())` - the happiness FIELD after the city pass
        goldenAgeEndTurn(civId: civId, happiness: happiness(of: civId))


        // Unciv TurnManager.endTurn: `civInfo.units.getCivUnits().forEach { UnitTurnManager(it).endTurn() }` -
        // each unit's whole end of turn (UnitTurnManager.swift) before the next unit's.
        for id in units.filter({ $0.civId == civId }).map({ $0.id }) { unitEndTurn(id) }
        // Unciv TurnManager.endTurn → DiplomacyManager.nextTurn for each of this civ's managers: the modifiers decay,
        // then the flags count down, both inside this civilization's own turn.
        // Unciv DiplomacyManager.nextTurn, from the civ's endTurn AFTER its cities, golden age and units:
        // nextTurnTrades first, then the modifiers and the flags.
        // Unciv: `civInfo.diplomacy.values.toList().forEach { it.nextTurn() }` - each manager runs all of its steps
        // (trades, untenable trades, open borders, modifiers, flags, city-state influence, smoothed opinion) before
        // the next one starts (DiplomacyTurnManager.swift).
        diplomacyTurnDoneThisRound.insert(civId)
        if civ(civId)?.isBarbarian != true { diplomacyManagersNextTurn(civId) }
        updateHasActiveEnemyMovementPenalty(civId)   // Unciv TurnManager.endTurn:345, right after the diplomacy managers
        // No updateViewableTiles here: Unciv's endTurn has none - the civ sees what its end of turn changed (a spy that
        // set up, an ally's tiles) at its next startTurn (TurnManager.kt:63). Ours refreshed the vision at the end of the
        // turn, so a spy's city was explored before the round's ranking was recorded (a state comparison, a test game, turn 14: Babylon's
        // Tiles Explored 124 against 118), and a natural wonder or a meeting it brought into view came a turn early.
        invalidateHappiness(civId)
        resetMilitaryMightCache(civId)   // Unciv TurnManager.endTurn:347, after the diplomacy managers and before updateWinningCiv
        checkVictory(winningCivOnly: civId)   // Unciv TurnManager.endTurn → updateWinningCiv ("Maybe we did something this turn to win"): this civ only
    }

    /// Unciv UnitTurnManager.endTurn: `if (unit.hasMovement() && tile.improvementInProgress != null &&
    /// unit.canBuildImprovement(...)) { if (tile.doWorkerTurn(unit)) tile.getCity()?.shouldReassignPopulation = true }`.
    /// The unit's side; the tile's side is `tileDoWorkerTurn` (TileImprovementFunctions.swift), Unciv's own chain.
    func doWorkerTurn(unitId: Int) {
        guard let ui = unitIndex(unitId) else { return }
        let u = units[ui]
        let civId = u.civId
        let tile = map[u.coord]
        // Unciv UnitTurnManager.endTurn: "if (unit.currentMovement > 0 …)" — a unit that used up its movement does not work this turn
        if epochsTradeDbg, u.def.isCivilian, let t0 = tile, t0.improvementInProgress != nil {
            let p = uncivPosition(u.coord)
            print("WRKMOVE t=\(turn) \(civ(civId)?.nation ?? "?")/\(u.name)@\(p.x),\(p.y) mv=\(u.movementLeft) order=\(u.order) imp=\(t0.improvementInProgress ?? "-"):\(t0.improvementTurnsLeft)")
        }
        // Unciv UnitTurnManager.endTurn asks nothing about the unit's ORDER: a unit with movement left,
        // standing on a tile with an improvement in progress that it could build, works it. We required a
        // .build order, so a worker that walked back onto its own half-built road sat there for a turn
        // before resuming it - Unciv finished the road at `settled` turn 59 and we at turn 60.
        // A build order whose improvement is no longer on the tile is stale: drop it, as we always did.
        if case .build(let ordered) = u.order, tile?.improvementInProgress != ordered { units[ui].order = .none }
        guard u.movementLeft > 0, let t = tile, let imp = t.improvementInProgress, unitCanBuildImprovement(u, imp, t) else { return }
        // Unciv Tile.doWorkerTurn → TileImprovementFunctions.setImprovement(entry, worker.civ, worker): the queue entry
        // leaves the queue, the improvement (or road, removal, repair) is applied, its uniques are triggered, and
        // `updateCity()` refreshes the OWNING city's stats, the owner's resources and defers its reassignment.
        let hadNext = t.queuedImprovement
        guard tileDoWorkerTurn(at: u.coord, workerId: unitId) else { return }
        // Unciv Tile.doWorkerTurn: `if (worker.civ.isCurrentPlayer()) addCompletedTutorialTask("Construct an improvement")` -
        // GameInfo.nextTurn walks the AIs with currentPlayerCiv still the human (it is set only once a human is found),
        // so an AI worker never completes it - the same `== playerId` test meetCiv's "Meet another civilization" uses
        if civId == playerId { Tutorial.markTaskDone("Construct an improvement") }
        // Our unit carries the order it was given; Unciv's worker simply stands on the tile's next queue entry.
        // Unciv's doWorkerTurn leaves the unit's action alone (Tile.kt:1120-1132), so a road-connecting worker (action
        // ConnectRoad) walks on along its path the next turn and a sleeping or fortified worker stays asleep: only our own
        // .build order, which stands for "works the tile's queue" and has no Unciv action, follows the queue. Clearing
        // every order left an automated worker without its road order and woke a worker put to sleep on its tile.
        if let wi = unitIndex(unitId), { switch units[wi].order { case .none, .build: return true; default: return false } }() {
            units[wi].order = .none
            if let next = hadNext, map[u.coord]?.improvementInProgress == next { units[wi].order = .build(next) }
        }
        // Unciv UnitTurnManager.endTurn: `if (tile.doWorkerTurn(unit)) tile.getCity()?.shouldReassignPopulation = true`
        if let city = owningCity(u.coord), let ci = cityIndex(city.id) { cities[ci].shouldReassignPopulation = true }
    }

    /// Unciv TurnManager.endTurn: up to 3 promotable units are listed one by one, more collapse into a single count.
    func notifyPromotableUnits(_ civId: Int) {
        // Unciv runs this for every civ; addNotification drops what an AI civ is told
        let promotable = units.filter { $0.civId == civId && promotionsAvailable($0) > 0 && !availablePromotions(for: $0).isEmpty }
        if promotable.count <= 3 {
            for u in promotable { notify(civId, "[\(uncivDisplayName(u))] can be promoted!", category: .Units, icons: [u.name], actions: [.unit(u.coord, u.id), .promoteUnit(u.customName ?? u.name, u.coord, u.id)]) }
        } else {
            notify(civId, "[\(promotable.count)] units can be promoted!", category: .Units, icons: ["UnitActionIcons/Promote"], actions: promotable.map { .unit($0.coord, $0.id) })
        }
    }
}
