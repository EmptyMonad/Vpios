// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
extension GameState {
    func activeQuests(for civId: Int) -> [(Quest, Civilization)] {
        cityStates.flatMap { cs in cs.quests.filter { $0.assigneeId == civId && (civ(civId)?.metCivs.contains(cs.id) ?? false) }.map { ($0, cs) } }
    }

    /// Unciv giveReward
    private func giveQuestReward(_ q: Quest, _ cs: Civilization) {
        guard let a = q.assigneeId else { return }
        let influence = questDef(q.name)?.influence ?? 40
        if ProcessInfo.processInfo.environment["INFL"] != nil { print("QUESTE t=\(uncivTurns) \(cs.nation)->\(civ(a)?.nation ?? "?") \(q.name) target=\(q.target ?? "-") start=\(q.startTurn) end=\(q.endTurn) +\(influence)") }
        addInfluence(cityState: cs.id, major: a, influence)
        if influence > 0 { notify(a, "[\(cs.nation)] rewarded you with [\(Int(influence))] influence for completing the [\(q.name)] quest.", category: .Diplomacy, icons: [cs.nation, "Quest"], actions: capital(of: cs.id).map { [.location($0.coord)] } ?? []) }   // addQuestNotification: LocationAction(the city-state's capital)
        invalidateHappiness(a)
        // Unciv QuestManager.giveReward ends in `for (city in civ.cities) city.cityStats.update()` - `civ` is
        // the city-state handing out the reward, whose influence with the assignee just moved, which can move
        // an alliance and with it what its cities are worth.
        for c in cities(of: cs.id) { updateCityStats(c.id, reason: "QuestManager:1137") }
    }

    /// Unciv notifyExpired
    private func notifyQuestExpired(_ q: Quest, _ cs: Civilization, winners: [Quest] = []) {
        guard let a = q.assigneeId else { return }
        if winners.isEmpty { notify(a, "[\(cs.nation)] no longer needs your help with the [\(q.name)] quest.", category: .Diplomacy, icons: [cs.nation, "Quest"], coord: capital(of: cs.id)?.coord) }
        else { notify(a, "The [\(q.name)] quest for [\(cs.nation)] has ended. It was won by [\(winners.compactMap { $0.assigneeId.flatMap { civ($0)?.nation }.map { "{\($0)}" } }.joined(separator: ", "))].", category: .Diplomacy, icons: [cs.nation, "Quest"], coord: capital(of: cs.id)?.coord) }
    }

    private func assignQuest(_ def: QuestDef, _ csId: Int, _ assignees: [Civilization]) {
        guard let ci = civIndex(csId) else { return }
        for m in assignees {
            guard let data = questData(def, civs[ci], m) else { continue }
            let end = def.duration > 0 ? turn + Int(speed.modifier * Double(def.duration)) : 0   // Unciv AssignedQuest.getDuration
            let questId = newId()
            civs[ci].quests.append(Quest(id: questId, name: def.name, cityStateId: csId, assigneeId: m.id, target: data.isEmpty ? nil : data, startTurn: turn, endTurn: end))
            if !def.isGlobal { civs[ci].individualQuestCountdown[m.id] = -1 }
            // Unciv getNotificationActions: DiplomacyAction(city-state), the camp's LocationAction first for Clear Barbarian Camp
            var questActions: [NotificationAction] = [.diplomacy(civs[ci].nation)]
            if def.name == "Clear Barbarian Camp" { let parts = data.split(separator: ","); if parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]) { questActions.insert(.location(HexCoord(x, y)), at: 0) } }
            notify(m.id, "[\(civs[ci].nation)] assigned you a new quest: [\(def.name)].", category: .Diplomacy, icons: [civs[ci].nation, "Quest"], actions: questActions)
        }
    }

    /// Unciv QuestManager.endTurn for every city-state with a city
    /// Unciv QuestManager.endTurn, called from the CITY-STATE's own `TurnManager.endTurn` (line 291) - before
    /// that same endTurn walks `diplomacy.values.forEach { it.nextTurn() }` (line 344), which is where influence
    /// decays. So a quest completed this turn pays its influence and then decays with everything else, in the
    /// same turn. `only` is that one city-state.
    func questsTurn(only: Int? = nil) {
        for cs0 in cityStates where only == nil || cs0.id == only {
            guard let ci = civIndex(cs0.id) else { continue }
            // Unciv QuestManager.endTurn: a defeated city-state drops all quests and resets both countdowns
            if isDefeated(civs[ci]) {
                civs[ci].quests.removeAll()
                civs[ci].individualQuestCountdown.removeAll()
                civs[ci].globalQuestCountdown = -1
                continue
            }
            guard !cities(of: cs0.id).isEmpty else { continue }
            let turns = turn - 1   // Unciv gameInfo.turns
            // seedGlobalQuestCountdown / seedIndividualQuestsCountdowns (× game speed)
            if turns >= 30 && civs[ci].globalQuestCountdown == -1 {
                // Unciv QuestManager.kt:196-201: `civ.state.stateBasedRandom("QuestManager.seedGlobalQuestCooldown")`, nextInt(20) / 40 + nextInt(25)
                var g = stateBasedRandom("QuestManager.seedGlobalQuestCooldown", civId: civs[ci].id)
                let c = turns == 30 ? g.nextInt(below: 20) : 40 + g.nextInt(below: 25)
                civs[ci].globalQuestCountdown = Int(Double(c) * speed.modifier)
            }
            if turns >= 30 {
                for m in majorCivs where (civs[ci].individualQuestCountdown[m.id] ?? -1) == -1 {
                    // Unciv QuestManager.kt:218-226: `civ.state.copy(otherCiv = challenger).stateBasedRandom("QuestManager.seedIndividualQuestCooldown")`
                    var g = stateBasedRandom("QuestManager.seedIndividualQuestCooldown", civId: civs[ci].id, otherCivId: m.id)
                    let c = turns == 30 ? g.nextInt(below: 20) : 20 + g.nextInt(below: 25)
                    civs[ci].individualQuestCountdown[m.id] = Int(Double(c) * speed.modifier)
                }
            }
            // decrementQuestCountdowns
            if civs[ci].globalQuestCountdown > 0 { civs[ci].globalQuestCountdown -= 1 }
            for (k, v) in civs[ci].individualQuestCountdown where v > 0 { civs[ci].individualQuestCountdown[k] = v - 1 }
            // handleGlobalQuests: drop participants that can no longer take part, then settle expired contests
            let snapshot = civs[ci]
            let dropped = Set(snapshot.quests.filter { q in isGlobalQuest(q) && !(q.assigneeId.flatMap { civ($0) }.map { canAssignQuest(snapshot, to: $0) } ?? false) }.map { $0.id })
            civs[ci].quests.removeAll { dropped.contains($0.id) }
            for name in Set(civs[ci].quests.filter { isGlobalQuest($0) && $0.endTurn > 0 && turn >= $0.endTurn }.map { $0.name }).sorted() {
                let cs = civs[ci]
                let (winners, maxScore) = questWinners(name, cs)
                for w in winners { giveQuestReward(w, cs) }
                for l in cs.quests where l.name == name && !winners.contains(where: { $0.id == l.id }) && questScore(l) > 0 && questScore(l) < maxScore { notifyQuestExpired(l, cs, winners: winners) }
                civs[ci].quests.removeAll { $0.name == name }
            }
            // handleIndividualQuests
            let current = civs[ci]
            var remove: Set<Int> = []
            for q in current.quests where !isGlobalQuest(q) {
                guard let a = q.assigneeId, let m = civ(a), canAssignQuest(current, to: m) else { remove.insert(q.id); continue }
                if isQuestComplete(q, current) { giveQuestReward(q, current); remove.insert(q.id) }
                else if isQuestObsolete(q, current) || (q.endTurn > 0 && turn >= q.endTurn) { notifyQuestExpired(q, current); remove.insert(q.id) }
            }
            civs[ci].quests.removeAll { remove.contains($0.id) }
            // tryStartNewGlobalQuest
            let forGlobal = civs[ci]
            if forGlobal.globalQuestCountdown == 0 && !forGlobal.quests.contains(where: { isGlobalQuest($0) }) {
                // Unciv counts over `civ.getKnownCivs().filter { it.isMajorCiv() && !it.isAtWarWith(civ) }`,
                // and `getKnownCivs` drops the defeated. Ours counted every major it had ever met, dead ones
                // included, so a quest could clear `minimumCivs` on civs that no longer exist.
                let known = knownCivs(forGlobal.id).filter { $0.isMajor && !forGlobal.isAtWar(with: $0.id) }
                let assignable = rs.quests.filter { d in d.isGlobal && known.filter { isQuestValid(d, forGlobal, $0) }.count >= d.minimumCivs }
                if let def = randomWeightedQuest(assignable, forGlobal) {
                    assignQuest(def, forGlobal.id, majorCivs.filter { !forGlobal.isAtWar(with: $0.id) && isQuestValid(def, forGlobal, $0) })
                    civs[ci].globalQuestCountdown = -1
                }
            }
            // tryStartNewIndividualQuests (at most 2 individual quests per major)
            // Unciv HashMap<String, Int> keyed by civ name: bucket order, then insertion order (seeded in civ-list order)
            let cdKeys = Array(civs[ci].individualQuestCountdown.keys)
            var cdCapacity = 16
            while cdKeys.count > cdCapacity * 3 / 4 { cdCapacity <<= 1 }
            let cdOrder = cdKeys.map { ($0, javaBucket(civ($0)?.nation ?? "", capacity: cdCapacity), civIndex($0) ?? Int.max) }
                .sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map { $0.0 }
            for challengerId in cdOrder where civs[ci].individualQuestCountdown[challengerId] == 0 {
                let cs = civs[ci]
                guard let m = civ(challengerId), cs.quests.filter({ $0.assigneeId == challengerId && !isGlobalQuest($0) }).count < 2 else { continue }
                if let def = randomWeightedQuest(rs.quests.filter { !$0.isGlobal && isQuestValid($0, cs, m) }, cs, challenger: m.id) { assignQuest(def, cs.id, [m]) }
            }
            tryBarbarianInvasion(cityState: civs[ci])
            tryEndWarWithMajorQuests(cityState: civs[ci].id)   // Unciv QuestManager.endTurn ends with tryEndWarWithMajorQuests
        }
    }

    /// Unciv QuestManager.barbarianCampCleared: camp quests for this exact tile; the clearer's own quest is rewarded, all are removed
    func onCampCleared(at c: HexCoord, by civId: Int) {
        let key = "\(c.q),\(c.r)"
        for cs in cityStates {
            guard let ci = civIndex(cs.id) else { continue }
            if let win = civs[ci].quests.first(where: { $0.name == "Clear Barbarian Camp" && $0.target == key && $0.assigneeId == civId }) { giveQuestReward(win, civs[ci]) }
            civs[ci].quests.removeAll { $0.name == "Clear Barbarian Camp" && $0.target == key }
        }
    }

    /// Unciv QuestManager.handleObsoleteGlobalQuests: despite the name, EVERY assigned quest that can no longer be
    /// fulfilled is expired and removed, one by one. Unciv calls it on every alive city-state whenever a barbarian
    /// encampment is removed (TileImprovementFunctions.setImprovement(null)) - not from QuestManager.endTurn.
    /// Ours ran an invented pass at every city-state endTurn that dropped every GLOBAL quest sharing an obsolete
    /// quest's name, so a second assignee's Clear Barbarian Camp quest for another, standing camp went too.
    func handleObsoleteQuests(cityState csId: Int) {
        guard let ci = civIndex(csId), civs[ci].isAlive else { return }
        let cs = civs[ci]
        let obsolete = cs.quests.filter { isQuestObsolete($0, cs) }
        guard !obsolete.isEmpty else { return }
        for q in obsolete { notifyQuestExpired(q, cs) }
        let ids = Set(obsolete.map { $0.id })
        civs[ci].quests.removeAll { ids.contains($0.id) }
    }

    /// Unciv QuestManager.receivedGoldGift: the donor's Give Gold quests, any amount
    func onGoldGifted(to cityStateId: Int, by civId: Int, amount: Double) {
        guard let ci = civIndex(cityStateId) else { return }
        for q in civs[ci].quests where q.name == "Give Gold" && q.assigneeId == civId { giveQuestReward(q, civs[ci]) }
        civs[ci].quests.removeAll { $0.name == "Give Gold" && $0.assigneeId == civId }
    }

    /// Unciv QuestManager.cityStateConquered: only the attacker's Conquer City State quests
    func questsCityStateConquered(target: Int, attacker: Int) {
        for cs in cityStates {
            guard let ci = civIndex(cs.id) else { continue }
            let matching = civs[ci].quests.filter { $0.name == "Conquer City State" && $0.target == String(target) && $0.assigneeId == attacker }
            for q in matching { giveQuestReward(q, civs[ci]) }
            civs[ci].quests.removeAll { q in matching.contains { $0.id == q.id } }
        }
    }

    // MARK: protection
    func canPledgeProtection(_ civId: Int, _ cs: Int) -> Bool {
        // Unciv otherCivCanPledgeProtection: a city-state that knows us, not at war from ITS side, not protected by us yet
        guard let m = civ(civId), m.isMajor, m.isAlive, let c = civ(cs), c.isCityState, c.metCivs.contains(civId), !c.isAtWar(with: civId), !m.protectedCityStates.contains(cs) else { return false }
        // Unciv otherCivCanPledgeProtection: can't pledge too soon after withdrawing
        if hasFlag(cs, civId, "RecentlyWithdrewProtection") { return false }
        return influence(of: civId, with: cs) >= 0
    }

    /// Unciv CityStateFunctions.addProtectorCiv: the status (the +10 is on the resting point) and the flag.
    func pledgeProtection(_ civId: Int, _ cs: Int) {
        guard canPledgeProtection(civId, cs), let i = civIndex(civId), civIndex(cs) != nil else { return }
        civs[i].protectedCityStates.insert(cs)
        setFlag(cs, civId, "RecentlyPledgedProtection", 10)   // Unciv addProtectorCiv: can't break for 10 turns
    }

    /// Unciv CityStateFunctions.removeProtectorCiv(otherCiv, forced = false): refused unless forced or
    /// otherCivCanWithdrawProtection. The "Very well." answer to a bullied/attacked protégé forces it - even within
    /// 10 turns of the pledge, and even for a mere ally who never pledged (status set to Peace, the flag and the -20).
    /// (War ends a protection separately, without the flag and the -20 - see DeclareWar.)
    func withdrawProtection(_ civId: Int, _ cs: Int, forced: Bool = false) {
        if !forced && !canWithdrawProtection(civId, cs) { return }
        guard let i = civIndex(civId), civIndex(cs) != nil else { return }
        civs[i].protectedCityStates.remove(cs)   // Unciv diplomaticStatus = Peace (nothing to remove for a mere ally)
        setFlag(cs, civId, "RecentlyWithdrewProtection", 20)   // Unciv removeProtectorCiv: can't re-pledge for 20 turns
        addInfluence(cityState: cs, major: civId, -20)
    }
}

// MARK: - Unciv QuestManager "war with major" pseudo-quest
extension GameState {

    func isWarWithMajorActive(cityState cs: Int, target: Int) -> Bool { civ(cs)?.unitsToKillForCiv[target] != nil }

    func unitsToKill(cityState cs: Int, target: Int) -> Int { civ(cs)?.unitsToKillForCiv[target] ?? 0 }

    func unitsKilledSoFar(cityState cs: Int, target: Int, by helper: Int) -> Int { civ(cs)?.unitsKilledFromCiv[target]?[helper] ?? 0 }

    /// Unciv notifyAskForAssistance: `assignee.addQuestNotification(message, location)`, the location being the
    /// city-state's `getCapital(firstCityIfNoCapital = true)?.location` - a LocationAction there (none without a city),
    /// NotificationCategory.Diplomacy, the city-state and NotificationIcon.Quest.
    private func notifyAskForAssistance(cityState cs: Civilization, assignee: Int, attacker: Int, unitsToKill: Int) {
        guard attacker != assignee, let a = civ(attacker) else { return }   // No "Hey Bob help us against Bob"
        let location = (capital(of: cs.id) ?? cities(of: cs.id).first)?.coord
        notify(assignee, "[\(cs.nation)] is being attacked by [\(a.nation)]! Kill [\(unitsToKill)] of the attacker's military units and they will be immensely grateful.", category: .Diplomacy, icons: [cs.nation, "Quest"], actions: location.map { [.location($0)] } ?? [])
    }

    /// wasAttackedBy: a quarter of the attacker's army (at least 3 units) is the price of the city-state's gratitude.
    func warWithMajorStarted(cityState cs: Int, attacker: Int) {
        guard let ci = civIndex(cs), civs[ci].isCityState else { return }
        let toKill = max(3, units(of: attacker).filter { $0.isMilitary }.count / 4)
        if civs[ci].unitsToKillForCiv.updateValue(toKill, forKey: attacker) == nil { civs[ci].unitsToKillPutOrder.append(attacker) }
        let csCiv = civs[ci]
        // Unciv `civ.forEachKnownCiv`: neither a defeated civ nor the Spectator, then majors not at war with the city-state
        for third in knownCivs(cs) where !third.isSpectator && third.isMajor && !third.isAtWar(with: cs) { notifyAskForAssistance(cityState: csCiv, assignee: third.id, attacker: attacker, unitsToKill: toKill) }
    }

    /// justMet: newcomers hear about the wars still running, `for ((attackerName, unitsToKill) in unitsToKillForCiv)`.
    func warWithMajorJustMet(cityState cs: Int, other: Int) {
        guard let c = civ(cs), c.isCityState, !c.unitsToKillForCiv.isEmpty, civ(other)?.isMajor == true else { return }
        // Unciv `for ((attackerName, unitsToKill) in unitsToKillForCiv)`: a HashMap<String, Int> keyed by civID (the civ's
        // name), walked in its bucket order - the newcomer's notifications come in that order, not by our civ ids
        for attacker in unitsToKillHashOrder(c) {
            guard let n = c.unitsToKillForCiv[attacker] else { continue }
            notifyAskForAssistance(cityState: c, assignee: other, attacker: attacker, unitsToKill: n)
        }
    }

    /// unitsToKillForCiv's keys as Unciv's HashMap<String, Int> walks them: bucket by bucket (javaHashMapOrder, the capacity
    /// of the map's size since the Next Turn clone's `putAll` rebuilds it), and within a bucket in the order the keys were put
    /// (`put` appends to the bucket's chain; putAll copies in walk order, so a clone keeps it). A key the put order lacks
    /// (a save of ours from before it was kept) goes after, by id.
    func unitsToKillHashOrder(_ c: Civilization) -> [Int] {
        let keys = c.unitsToKillForCiv.keys
        let put = c.unitsToKillPutOrder.filter { keys.contains($0) }
        let ordered = put + keys.filter { !put.contains($0) }.sorted()
        let byName = Dictionary(ordered.compactMap { id in civ(id).map { ($0.nation, id) } }, uniquingKeysWith: { a, _ in a })
        return javaHashMapOrder(ordered.compactMap { civ($0)?.nation }).compactMap { byName[$0] }
    }

    /// militaryUnitKilledBy: credit the killer; the quest completes with +100 influence.
    func warWithMajorUnitKilled(killer: Int, killed: Int) {
        guard civ(killer) != nil else { return }   // Unciv militaryUnitKilledBy: any killer the city-state knows and is at peace with, city-states included
        for cs in cityStates where cs.isAlive && cs.unitsToKillForCiv[killed] != nil && cs.metCivs.contains(killer) && !cs.isAtWar(with: killer) {
            guard let ci = civIndex(cs.id) else { continue }
            let count = (civs[ci].unitsKilledFromCiv[killed]?[killer] ?? 0) + 1
            civs[ci].unitsKilledFromCiv[killed, default: [:]][killer] = count
            if count >= (civs[ci].unitsToKillForCiv[killed] ?? Int.max) {
                notify(killer, "[\(cs.nation)] is deeply grateful for your assistance in the war against [\(civ(killed)?.nation ?? "?")]!", category: .Diplomacy, icons: [cs.nation, "Quest"], actions: [.diplomacy(cs.nation)])   // addDiplomacyNotification
                // Unciv `civ.getDiplomacyManager(killer)!!.addInfluence(100f)`: the Float sum, the -60 floor, updateAllyCivForCityState
                addInfluence(cityState: cs.id, major: killer, 100)
                endWarWithMajorQuest(cityState: cs.id, attacker: killed)
            }
        }
    }

    func endWarWithMajorQuest(cityState cs: Int, attacker: Int) {
        guard let ci = civIndex(cs) else { return }
        let c = civs[ci]
        // Unciv `civ.forEachKnownCiv`: every civ the city-state knows that is neither defeated nor the Spectator - the
        // other city-states too, not only the majors asked for help
        for third in knownCivs(cs) where !third.isSpectator && third.id != attacker && !third.isAtWar(with: cs) {
            if unitsKilledSoFar(cityState: cs, target: attacker, by: third.id) >= unitsToKill(cityState: cs, target: attacker) { continue }   // the winner already heard the good news
            notify(third.id, "[\(c.nation)] no longer needs your assistance against [\(civ(attacker)?.nation ?? "?")].", category: .Diplomacy, icons: [c.nation, "Quest"], actions: [.diplomacy(c.nation)])   // addDiplomacyNotification
        }
        civs[ci].unitsToKillForCiv[attacker] = nil
        civs[ci].unitsToKillPutOrder.removeAll { $0 == attacker }
        civs[ci].unitsKilledFromCiv[attacker] = nil
    }

    /// tryEndWarWithMajorQuests: wars that ended (or civs that died) close the quest.
    func tryEndWarWithMajorQuests(cityState cs: Int) {
        guard let c = civ(cs) else { return }
        // Unciv `for (attacker in unitsToKillForCiv.keys.map { ... })`: the HashMap's walk, where ours walked a Swift dictionary
        for attacker in unitsToKillHashOrder(c) where !c.isAlive || civ(attacker)?.isAlive != true || !c.isAtWar(with: attacker) { endWarWithMajorQuest(cityState: cs, attacker: attacker) }
    }

    /// Unciv QuestManager.cityStateBullied on every city-state: the bully's Bully City State quests against it are rewarded; the bullied
    /// city-state revokes the bully's individual and Invest quests
    func revokeQuestsAfterTribute(cityState csId: Int, bully: Int) {
        for other in cityStates {
            guard let oi = civIndex(other.id) else { continue }
            let matching = civs[oi].quests.filter { $0.name == "Bully City State" && $0.target == String(csId) && $0.assigneeId == bully }
            for q in matching { giveQuestReward(q, civs[oi]) }
            civs[oi].quests.removeAll { q in matching.contains { $0.id == q.id } }
        }
        guard let ci = civIndex(csId) else { return }
        let revoked = civs[ci].quests.filter { $0.assigneeId == bully && (!isGlobalQuest($0) || $0.name == "Invest") }
        guard !revoked.isEmpty else { return }
        civs[ci].quests.removeAll { q in revoked.contains { $0.id == q.id } }
        notify(bully, "[\(civs[ci].nation)] cancelled the quests they had given you because you demanded tribute from them.", category: .Diplomacy, icons: [civs[ci].nation, "Quest"], actions: [.diplomacy(civs[ci].nation)])   // addDiplomacyNotification
    }
}
