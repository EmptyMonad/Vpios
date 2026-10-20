// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv BattleTable / CityPresenter: strengths through Number.tr (`getAttackingStrength().tr() + attackIcon`)
fileprivate func trNum(_ n: Int) -> String { Translations.shared.numberTr(n) }

/// Unciv BattleTable (bottom bar): attacker vs defender, their strength, the named modifiers, the health both would keep, and an Attack button.
struct BattleTableView: View {
    @ObservedObject var controller: GameController
    let attacker: Unit
    let target: HexCoord

    /// Unciv BattleTable.update: a nuclear weapon draws simulateNuke, an air unit told to sweep draws simulateAirsweep, anything else simulateBattle.
    private var isNuke: Bool { attacker.def.uniqueObjects.contains { $0.pattern == "Nuclear weapon of Strength []" } }
    private var isAirSweep: Bool { attacker.def.isAir && controller.sweepMode }

    var body: some View {
        Group {
            if isNuke { nukeTable }
            else if isAirSweep { airSweepTable }
            else { battleTable }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelDark.opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.8), lineWidth: 1.5))
        .overlay(alignment: .topTrailing) { Button { controller.battleTarget = nil; controller.refresh(full: false) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.gold) }.offset(x: 6, y: -6) }
        .frame(maxWidth: 320)
    }

    /// Unciv BattleTable.update / simulateBattle: the defender is tryGetDefender's - TileView.getCombatant, the city on its
    /// centre, else the visible unit - and everything is weighed from the tileToAttackFrom of the first getAttackableEnemies
    /// entry for its tile (the unit's own tile when there is none).
    @ViewBuilder private var battleTable: some View {
        if let d = controller.visibleCombatant(at: target) { simulateBattle(controller.state, d) }
    }

    /// Unciv BattleTable.simulateBattle for a unit attacker.
    @ViewBuilder private func simulateBattle(_ s: GameState, _ d: Combatant) -> some View {
        let a: Combatant = .probe(attacker)
        let city = s.cCity(d)
        let defender: Unit? = d.isCity ? nil : s.cUnit(d)
        let from = controller.attackOrigins[target] ?? attacker.coord
        let preview = s.combatPreview(attacker: attacker, targetTile: target, resolving: false, attackFrom: from, shownDefender: d)
        let ranged = s.cIsRanged(a)
        // Unciv BattleTable.simulateBattle: the ranged icon for the defender only when both sides fight at range, and not
        // for a city or an embarked unit
        let attackIcon = ranged ? "🏹" : "⚔️"
        let defenceIcon = ranged && s.cIsRanged(d) && !d.isCity && !(defender.map { s.isEmbarked($0) } ?? false) ? "🏹" : "⚔️"
        // Unciv: attacker.getAttackModifiers(defender, tileToAttackFrom); defender.getDefenceModifiers(...) unless a city
        let attackMods = s.getAttackModifiers(a, d, tileToAttackFrom: from).entries
        let defenceMods = d.isCity ? [] : s.getDefenceModifiers(a, d, tileToAttackFrom: from).entries
        VStack(spacing: 5) {
            // Unciv ICombatant.getName: a unit's name (not the one the player gave it), a city's name
            HStack(spacing: 8) {
                combatant(name: attacker.name, icon: attacker.name, folder: "UnitIcons", civ: s.civ(attacker.civId))
                Text("⚔️").font(.system(size: 12))
                if let c = city { combatant(name: c.name, icon: "", folder: "", civ: s.civ(c.civId)) }
                else if let du = defender { combatant(name: du.name, icon: du.name, folder: "UnitIcons", civ: s.civ(du.civId)) }
            }
            if let p = preview {
                // Unciv BattleTable: ICombatant.getAttackingStrength / getDefendingStrength, the Int strength before any modifier
                HStack(spacing: 12) {
                    Text(trNum(s.combatantAttackingStrength(a, defender: d)) + attackIcon).font(Theme.caption.bold())
                    Text(trNum(s.combatantDefendingStrength(d, attacker: a)) + defenceIcon).font(Theme.caption.bold())
                }
                HStack(alignment: .top, spacing: 8) {
                    modifiers(attackMods)
                    if !defenceMods.isEmpty { modifiers(defenceMods) } else { Spacer().frame(width: 100) }
                }
                // Unciv BattleTable: once any modifier applies, a second row shows getFinalAttackingStrength /
                // getFinalDefendingStrength from the same tile, roundToInt
                if !attackMods.isEmpty || !defenceMods.isEmpty {
                    Rectangle().fill(Theme.goldDim).frame(width: 220, height: 1)
                    HStack(spacing: 12) {
                        Text(trNum(Stats.roundToInt(Double(s.getAttackingStrength(a, d, tileToAttackFrom: from)))) + attackIcon).font(Theme.caption.bold())
                        Text(trNum(Stats.roundToInt(Double(s.getDefendingStrength(a, d, tileToAttackFrom: from)))) + defenceIcon).font(Theme.caption.bold())
                    }
                }
                // Unciv BattleTable, from Battle.addXp: ForeignMapUnitView.hasReachedMaxXPFromBarbarians is
                // promotions.totalXpProduced() >= maxXPfromBarbarians - the XP spent on promotions counts too
                if s.civ(s.cCivId(d))?.isBarbarian == true, attacker.totalXpProduced >= s.rs.constants.maxXPfromBarbarians {
                    Text(L("Cannot gain more XP from Barbarians")).font(Theme.small).foregroundStyle(Theme.creamDim)
                }
                // Unciv BattleTable: melee attacks on a civilian or a defeated city show the outcome instead of damage.
                // `defenderIsCivilian` needs a MapUnitCombatantView - on a city centre the defender is the city, whatever
                // civilian stands inside.
                let defenderIsCivilian = s.cIsCivilian(d)
                if !ranged && (defenderIsCivilian || (d.isCity && s.cIsDefeated(d))) {
                    let defeatedText = !defenderIsCivilian ? "Occupied!" : ((defender.map { s.unitHasUnique($0, "Uncapturable") } ?? false) ? "" : "Captured!")
                    if !defeatedText.isEmpty { Text(L(defeatedText)).font(Theme.caption).foregroundStyle(Theme.gold) }
                }
                else {
                    if !d.isCity && p.hasExtraRangedAttack { Text(L("Will perform an extra ranged attack")).font(Theme.small).foregroundStyle(Theme.creamDim) }
                    // Unciv BattleTable: calculateDamageTo…(randomnessFactor 1f / 0f), capped at the remaining health;
                    // the average is `values.average().roundToInt()` of the two capped losses
                    let aHealth = attacker.health, dHealth = s.cHealth(d)
                    let dMaxHealth = city.map { s.cityMaxHealth($0) } ?? 100   // ICombatant.getMaxHealth
                    let dMax = min(dHealth, p.maxDamageToDefender), dMin = min(dHealth, p.minDamageToDefender)
                    let aMax = min(aHealth, p.maxDamageToAttacker), aMin = min(aHealth, p.minDamageToAttacker)
                    let aAvg = Stats.roundToInt(Double(aMin + aMax) / 2), dAvg = Stats.roundToInt(Double(dMin + dMax) / 2)
                    HStack(spacing: 12) {
                        healthBar(max: 100, current: aHealth, minLeft: aHealth - aMax, maxLeft: aHealth - aMin)
                        healthBar(max: dMaxHealth, current: dHealth, minLeft: dHealth - dMax, maxLeft: dHealth - dMin, mirror: true)
                    }
                    HStack(spacing: 12) {
                        Text(L(aMax == 0 ? "\(aHealth)" : aMin == aMax ? "\(aHealth) → \(aHealth - aMax) (\(aAvg))" : "\(aHealth) → \(aHealth - aMax)-\(aHealth - aMin) (~\(aAvg))")).font(Theme.small)
                        Text(L(dMin == dMax ? "\(dHealth) → \(dHealth - dMax) (\(dAvg))" : "\(dHealth) → \(dHealth - dMax)-\(dHealth - dMin) (~\(dAvg))")).font(Theme.small)
                    }
                }
            }
            Button(L("Attack")) { controller.pendingMove = nil; controller.attackBattleTarget(fromAttackButton: true) }   // Unciv BattleTable: the overlay was one of attacking
                // Unciv BattleTable: the attack button only `if (worldScreen.canChangeState)` - never for a spectator, who may select anyone's unit
                // Unciv BattleTable: without an attackableTileView (attacker.canAttack() and getAttackableEnemies) the button is greyed out
                .buttonStyle(ThemedButtonStyle(destructive: true, compact: true)).disabled(!controller.isMyTurn || controller.state.player.isSpectator || controller.isProcessing || !controller.attackable.contains(target))
        }
    }

    /// Unciv BattleTable.simulateNuke: the attacker over every combatant inside the blast radius the player can see,
    /// and a NUKE button mayUseNuke may grey out.
    @ViewBuilder private var nukeTable: some View {
        let s = controller.state
        let victims = nukeVictims(s)
        VStack(spacing: 5) {
            combatant(name: attacker.name, icon: attacker.name, folder: "UnitIcons", civ: s.civ(attacker.civId))   // ICombatant.getName
            // Unciv tryGetDefenderAtTile(includeFriendly = true): friend and foe alike are listed under the blast
            ForEach(Array(victims.enumerated()), id: \.offset) { _, v in
                combatant(name: v.name, icon: v.icon, folder: "UnitIcons", civ: s.civ(v.civId))
            }
            Button(L("NUKE")) { controller.pendingMove = nil; controller.attackBattleTarget() }
                // Unciv BattleTable.simulateNuke: `!isPlayersTurn || !attackerView.canAttack() || !canNuke` greys the button
                // out - MapUnit.canAttack is false without movement left (hasMovement), then attacksThisTurn < maxAttacksPerTurn;
                // mayUseNuke refuses a civ we may not attack
                .buttonStyle(ThemedButtonStyle(destructive: true, compact: true))
                .disabled(!controller.isMyTurn || controller.state.player.isSpectator || controller.isProcessing || attacker.movementLeft <= 0 || attacker.attacksThisTurn >= 1 + s.extraAttacks(of: attacker) || !s.mayUseNuke(attacker, target: target))
        }
    }

    /// Unciv BattleTable.simulateAirsweep: what the sweep will meet is unknown ("???"), so only our own strength,
    /// the air-sweep modifiers and two untouched health bars are shown.
    @ViewBuilder private var airSweepTable: some View {
        let s = controller.state
        let ctx = GameState.UniqueContext(civId: attacker.civId, unit: attacker, tile: s.map[attacker.coord], attacking: true)
        let base = s.unitAttackingStrength(attacker, ranged: attacker.def.isRanged, uniques: attacker.promotionUniques + s.civUniques(attacker.civId), ctx: ctx)
        // Unciv BattleDamage.getAirSweepAttackModifiers
        let mods = attacker.promotionUniques.filter { $0.pattern == "[]% Strength when performing Air Sweep" }.map { ($0.text, $0.int(0)) }
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                combatant(name: attacker.name, icon: attacker.name, folder: "UnitIcons", civ: s.civ(attacker.civId))   // ICombatant.getName
                Text("⚔️").font(.system(size: 12))
                Text("???").font(Theme.caption.bold())
            }
            HStack(spacing: 12) {
                Text(trNum(Int(base.rounded())) + "🏹").font(Theme.caption.bold())
                Text("???🏹").font(Theme.caption.bold())
            }
            HStack(alignment: .top, spacing: 8) {
                modifiers(mods)
                Spacer().frame(width: 100)
            }
            HStack(spacing: 12) {
                healthBar(max: 100, current: attacker.health, minLeft: attacker.health, maxLeft: attacker.health)
                healthBar(max: 100, current: 100, minLeft: 100, maxLeft: 100, mirror: true)
            }
            Button(L("Air Sweep")) { controller.pendingMove = nil; controller.attackBattleTarget() }
                .buttonStyle(ThemedButtonStyle(destructive: true, compact: true))
                .disabled(!controller.isMyTurn || controller.state.player.isSpectator || controller.isProcessing || !s.canAirSweep(attacker, target))
        }
    }

    /// Unciv BattleTable.simulateNuke: TileView.getVisibleTilesInDistance(blastRadius) - the EXPLORED tiles of the blast, in
    /// getTilesInDistance order - each contributing tryGetDefenderAtTile(includeFriendly = true): TileView.getCombatant, the
    /// city on its centre, else the unit the player can see there (never an undetected submarine).
    private func nukeVictims(_ s: GameState) -> [(name: String, icon: String, civId: Int)] {
        let radius = attacker.def.uniqueObjects.first { $0.pattern == "Blast radius []" }?.int(0) ?? s.nuclearBlastRadiusDefault
        return s.map.tilesWithin(target, radius: radius).compactMap { c -> (name: String, icon: String, civId: Int)? in
            guard let d = controller.visibleCombatant(at: c) else { return nil }
            if let city = s.cCity(d) { return (name: city.name, icon: "", civId: city.civId) }
            guard let u = s.cUnit(d) else { return nil }
            return (name: u.name, icon: u.name, civId: u.civId)   // ICombatant.getName
        }
    }

    private func combatant(name: String, icon: String, folder: String, civ: Civilization?) -> some View {
        HStack(spacing: 4) {
            if let c = civ { NationBadge(nation: c.nationDef, size: 18) }
            if !icon.isEmpty { ArtIcon(name: icon, folder: folder, fallback: "person.fill", size: 18) }
            Text(L(name)).font(Theme.caption.bold()).lineLimit(1)
        }
    }
    private func modifiers(_ list: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(list.enumerated()), id: \.offset) { _, m in
                HStack(spacing: 3) {
                    Text(m.1 > 0 ? "+\(m.1)%" : "\(m.1)%").font(.system(size: 9, weight: .bold)).foregroundStyle(m.1 > 0 ? Theme.good : Theme.danger)
                    Text(L(m.0)).font(.system(size: 9)).lineLimit(1)
                }
            }
        }.frame(width: 140, alignment: .leading)
    }
    /// Unciv BattleTableHelpers.getHealthBar
    private func healthBar(max: Int, current: Int, minLeft: Int, maxLeft: Int, mirror: Bool = false) -> some View {
        BattleHealthBar(maxHealth: max, currentHealth: current, maxRemaining: maxLeft, minRemaining: minLeft, forDefender: mirror)
    }
}

/// Unciv BattleTableHelpers.getHealthBar: 120 wide and 4 high - green what surely remains, orange what may be lost
/// (flashing to firebrick and back every 0.7s with continuous rendering), firebrick the sure loss, charcoal the
/// health already missing; the defender's bar is mirrored. The green part starts out covering the health the
/// unit has now and shrinks to what surely remains over 0.5s (for the defender it also slides back into place).
struct BattleHealthBar: View {
    let maxHealth: Int, currentHealth: Int, maxRemaining: Int, minRemaining: Int, forDefender: Bool
    @State private var shrunk = false
    @State private var pulse = false
    private static let firebrick = Color(red: 178 / 255, green: 34 / 255, blue: 34 / 255)
    private static let charcoal = Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255)   // ImageGetter.CHARCOAL
    private static let total: CGFloat = 120
    private func width(_ amount: Int) -> CGFloat { Swift.min(Self.total, Swift.max(0, Self.total * CGFloat(amount) / CGFloat(maxHealth))) }
    var body: some View {
        let green = width(minRemaining)
        let decrease = CGFloat(currentHealth - minRemaining) * Self.total / 100   // Unciv divides by 100 here
        let orange: Color = UserSettings.continuousRendering && pulse ? Self.firebrick : Color.orange
        HStack(spacing: 0) {
            if forDefender {
                Rectangle().fill(Self.charcoal).frame(width: width(maxHealth - currentHealth))
                Rectangle().fill(Self.firebrick).frame(width: width(currentHealth - maxRemaining))
                Rectangle().fill(orange).frame(width: width(maxRemaining - minRemaining))
                Rectangle().fill(Color.green).frame(width: green)
            } else {
                Rectangle().fill(Color.green).frame(width: green)
                Rectangle().fill(orange).frame(width: width(maxRemaining - minRemaining))
                Rectangle().fill(Self.firebrick).frame(width: width(currentHealth - maxRemaining))
                Rectangle().fill(Self.charcoal).frame(width: width(maxHealth - currentHealth))
            }
        }
        .frame(height: 4)
        // remainingHealthDot.toFront(): the animated green lies over its neighbours
        .overlay(alignment: forDefender ? .trailing : .leading) {
            Rectangle().fill(Color.green).frame(width: Swift.max(0, green + (shrunk ? 0 : decrease)), height: 4)
        }
        .onAppear {
            withAnimation(.linear(duration: 0.5)) { shrunk = true }
            if UserSettings.continuousRendering { withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true } }
        }
    }
}

/// Unciv CityPresenter: the selected city's name (with health when damaged), Strength and Bombard strength
struct CityPanel: View {
    @ObservedObject var controller: GameController
    let city: City
    var body: some View {
        let s = controller.state
        VStack(alignment: .leading, spacing: 4) {
            // Unciv UnitTable: the idle buttons on either side of the city's name too
            HStack(spacing: 6) {
                IdleUnitArrow(controller: controller, previous: true)
                Button { if controller.isMyTurn && city.civId == s.playerId { controller.showRenameCity = true } } label: { Text(city.health < s.cityMaxHealth(city) ? "\(L(city.name)) (\(city.health))" : L(city.name)).font(Theme.caption.bold()) }.buttonStyle(.plain)
                IdleUnitArrow(controller: controller, previous: false)
            }
            HStack { Text(L("Strength")).font(Theme.small); Spacer(); Text(trNum(Int(s.cityStrength(city).rounded()))).font(Theme.small.bold()) }
            HStack { Text(L("Bombard strength")).font(Theme.small); Spacer(); Text(trNum(Int((s.cityStrength(city, attacking: true) * 0.75).rounded()))).font(Theme.small.bold()) }
        }
        .padding(8).frame(width: 190)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelDark.opacity(0.95)))
        // Unciv UnitTable: a tap on the table centres the map on the city (CityPresenter.position; setCenterPosition,
        // selectUnit = false)
        .contentShape(Rectangle())
        .onTapGesture { controller.setCenterPosition(city.coord, selectUnit: false); controller.refresh(full: false) }
        .overlay(alignment: .topTrailing) { Button { controller.selectedCityId = nil; controller.battleTarget = nil; controller.refresh(full: false) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.gold) }.offset(x: 6, y: -6) }
    }
}

/// Unciv BattleTable.update with a selected city: simulateBattle(cityCombatant, defender, attacker.getTile()) against
/// tryGetDefender - TileView.getCombatant, the visible unit (a city is no target) - and a Bombard button.
struct CityBattleTableView: View {
    @ObservedObject var controller: GameController
    let city: City
    let target: HexCoord
    var body: some View {
        let s = controller.state
        VStack(spacing: 5) {
            if let d = controller.visibleCombatant(at: target), !d.isCity { simulateBattle(s, d) }
            // Unciv BattleTable: attackableTileView only when the city can attack and the tile is bombardable
            Button(L("Bombard")) { controller.bombardBattleTarget() }
                .buttonStyle(ThemedButtonStyle(destructive: true, compact: true)).disabled(!controller.isMyTurn || controller.isProcessing || !controller.attackable.contains(target))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelDark.opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.8), lineWidth: 1.5))
        .overlay(alignment: .topTrailing) { Button { controller.battleTarget = nil; controller.refresh(full: false) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.gold) }.offset(x: 6, y: -6) }
        .frame(maxWidth: 320)
    }

    /// Unciv BattleTable.simulateBattle for a city attacker: the same BattleDamage calls as for a unit, from the city's
    /// own tile. A city is ranged, so there is never an outcome line or return fire, and no extra-ranged-attack or
    /// barbarian-XP note (those need a MapUnitCombatantView attacker).
    @ViewBuilder private func simulateBattle(_ s: GameState, _ d: Combatant) -> some View {
        let a: Combatant = .city(city.id)
        let from = city.coord
        let defender = s.cUnit(d)
        // Unciv: the ranged icon for the defender when it is ranged and not embarked (a city always attacks at range)
        let defenceIcon = s.cIsRanged(d) && !(defender.map { s.isEmbarked($0) } ?? false) ? "🏹" : "⚔️"
        let attackMods = s.getAttackModifiers(a, d, tileToAttackFrom: from).entries
        let defenceMods = s.getDefenceModifiers(a, d, tileToAttackFrom: from).entries
        HStack(spacing: 8) {
            Text(L(city.name)).font(Theme.caption.bold())   // Unciv getCombatantName().toLabel()
            Text("⚔️").font(.system(size: 12))
            if let du = defender { Text(L(du.name)).font(Theme.caption.bold()).lineLimit(1) }   // ICombatant.getName
        }
        // Unciv BattleTable: raw strength on top (CityCombatant.getAttackingStrength, the defender's getDefendingStrength),
        // the named modifiers under it, and once any applies the strength they add up to below
        HStack(spacing: 12) {
            Text(trNum(s.combatantAttackingStrength(a, defender: d)) + "🏹").font(Theme.caption.bold())
            Text(trNum(s.combatantDefendingStrength(d, attacker: a)) + defenceIcon).font(Theme.caption.bold())
        }
        HStack(alignment: .top, spacing: 8) {
            if !attackMods.isEmpty { modifiers(attackMods) } else { Spacer().frame(width: 100) }
            if !defenceMods.isEmpty { modifiers(defenceMods) } else { Spacer().frame(width: 100) }
        }
        if !attackMods.isEmpty || !defenceMods.isEmpty {
            Rectangle().fill(Theme.goldDim).frame(width: 220, height: 1)
            HStack(spacing: 12) {
                Text(trNum(Stats.roundToInt(Double(s.getAttackingStrength(a, d, tileToAttackFrom: from)))) + "🏹").font(Theme.caption.bold())
                Text(trNum(Stats.roundToInt(Double(s.getDefendingStrength(a, d, tileToAttackFrom: from)))) + defenceIcon).font(Theme.caption.bold())
            }
        }
        // Unciv BattleTable: calculateDamageToDefender / calculateDamageToAttacker with randomnessFactor 1f and 0f, capped
        // at the remaining health; the average is `values.average().roundToInt()`
        let aHealth = city.health, dHealth = s.cHealth(d)
        let aMax = min(aHealth, s.calculateDamageToAttacker(a, d, tileToAttackFrom: from, randomnessFactor: 1))
        let aMin = min(aHealth, s.calculateDamageToAttacker(a, d, tileToAttackFrom: from, randomnessFactor: 0))
        let dMax = min(dHealth, s.calculateDamageToDefender(a, d, tileToAttackFrom: from, randomnessFactor: 1))
        let dMin = min(dHealth, s.calculateDamageToDefender(a, d, tileToAttackFrom: from, randomnessFactor: 0))
        let aAvg = Stats.roundToInt(Double(aMin + aMax) / 2), dAvg = Stats.roundToInt(Double(dMin + dMax) / 2)
        HStack(spacing: 12) {
            BattleHealthBar(maxHealth: s.cityMaxHealth(city), currentHealth: aHealth, maxRemaining: aHealth - aMin, minRemaining: aHealth - aMax, forDefender: false)
            BattleHealthBar(maxHealth: 100, currentHealth: dHealth, maxRemaining: dHealth - dMin, minRemaining: dHealth - dMax, forDefender: true)
        }
        HStack(spacing: 12) {
            Text(L(aMax == 0 ? "\(aHealth)" : aMin == aMax ? "\(aHealth) → \(aHealth - aMax) (\(aAvg))" : "\(aHealth) → \(aHealth - aMax)-\(aHealth - aMin) (~\(aAvg))")).font(Theme.small)
            Text(L(dMin == dMax ? "\(dHealth) → \(dHealth - dMax) (\(dAvg))" : "\(dHealth) → \(dHealth - dMax)-\(dHealth - dMin) (~\(dAvg))")).font(Theme.small)
        }
    }

    private func modifiers(_ list: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(list.enumerated()), id: \.offset) { _, m in
                HStack(spacing: 3) {
                    Text(m.1 > 0 ? "+\(m.1)%" : "\(m.1)%").font(.system(size: 9, weight: .bold)).foregroundStyle(m.1 > 0 ? Theme.good : Theme.danger)
                    Text(L(m.0)).font(.system(size: 9)).lineLimit(1)
                }
            }
        }.frame(width: 140, alignment: .leading)
    }
}
