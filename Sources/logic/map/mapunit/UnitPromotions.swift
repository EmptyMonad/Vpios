// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/map/mapunit/UnitPromotions.kt`: experience, the promotions it buys and the tree they sit in.
extension GameState {
    /// Unciv Battle.addXp: flat/percent XP uniques, a 30-XP cap against barbarians, and great-general points equal to the XP gained.
    func grantXP(unitId: Int, _ amount: Int, against opponentCiv: Int? = nil) {
        // Unciv Battle.addXp asks only for a MapUnitCombatant: a civilian that survives a ranged attack gains its
        // 2 XP - and its civ the great general points - like anyone else (settled turn 101: a Japanese worker).
        guard let i = unitIndex(unitId) else { return }
        let otherIsBarbarian = opponentCiv.flatMap { civ($0)?.isBarbarian } ?? false
        if otherIsBarbarian && units[i].totalXpProduced >= rs.constants.maxXPfromBarbarians { return }   // Unciv totalXpProduced   // Unciv ModConstants.maxXPfromBarbarians
        var xp = Double(amount)
        let ctx = UniqueContext(civId: units[i].civId, unit: units[i])
        // Unciv Battle.addXp: flat and percentage XP uniques both from the unit and the civ
        let xpUniques = units[i].promotionUniques + civUniques(units[i].civId)
        for u in xpUniques where u.pattern == "[] XP gained from combat" && conditionalsHold(u, ctx) { xp += u.double(0) }
        let xpBonus = xpUniques.filter { $0.pattern == "[]% XP gained from combat" && conditionalsHold($0, ctx) }.reduce(0.0) { $0 + $1.double(0) }
        xp *= 1 + xpBonus / 100
        let gained = Int(xp)
        migratePromotionState(i)
        // Unciv Battle.addXp: a unit that crosses a promotion threshold in combat is announced there and then,
        // not only at the start of the next turn.
        let couldAlreadyPromote = promotionsAvailable(units[i]) > 0 && !availablePromotions(for: units[i]).isEmpty
        units[i].xp += gained
        if !otherIsBarbarian, opponentCiv != nil, let ci = civIndex(units[i].civId), civs[ci].isMajor {
            let nation = civs[ci].nation
            for gp in rs.units.values where gp.greatPersonType != nil {
                // Unciv Battle.addXp: only great generals allowed for this civ (not another nation's unique, not replaced by our unique unit)
                if let owner = gp.uniqueTo, owner != nation { continue }
                if rs.units.values.contains(where: { $0.uniqueTo == nation && $0.replaces == gp.name }) { continue }
                for u in gp.uniqueObjects where u.pattern == "Can be earned through combat" && unitMatches(units[i], u.conditional("for [] units")?.param(0) ?? "Military") {
                    let bonus = xpUniques.filter { $0.pattern == "[] is earned []% faster" && ($0.param(0) == gp.name || $0.param(0) == gp.replaces) && conditionalsHold($0, ctx) }.reduce(0.0) { $0 + $1.double(1) }
                    let add = Int(Double(gained) * (1 + bonus / 100))   // Unciv greatGeneralPointsCounter (truncated)
                    let now = (civs[ci].greatGeneralPoints[gp.name] ?? 0) + add
                    if now == 0 { civs[ci].greatGeneralPoints[gp.name] = nil; civs[ci].greatGeneralOrder.removeAll { $0 == gp.name } }   // a Counter drops a zero
                    else {
                        if civs[ci].greatGeneralPoints[gp.name] == nil { civs[ci].greatGeneralOrder.append(gp.name) }
                        civs[ci].greatGeneralPoints[gp.name] = now
                    }
                    break
                }
            }
        }
        if !couldAlreadyPromote, units[i].health > 0, promotionsAvailable(units[i]) > 0, !availablePromotions(for: units[i]).isEmpty {
            let u = units[i]
            notify(u.civId, "[\(uncivDisplayName(u))] can be promoted!", category: .Units, icons: [u.name], actions: [.unit(u.coord, u.id), .promoteUnit(u.customName ?? u.name, u.coord, u.id)])
        }
    }

    func availablePromotions(for unit: Unit) -> [PromotionDef] {
        let candidates = rs.promotions(forUnitType: unit.def.unitType).filter { p in
            !unit.promotions.contains(p.name) && p.prerequisites.isEmpty || p.prerequisites.contains { unit.promotions.contains($0) }
        }.filter { !unit.promotions.contains($0.name) }.filter { p in
            // Unciv PromotionPicker isAvailable: "Only available" and "Unavailable" conditionals
            let ctx = UniqueContext(civId: unit.civId, unit: unit)
            return !p.uniqueObjects.contains(where: { $0.pattern == "Only available" && !conditionalsHold($0, ctx) }) && !p.uniqueObjects.contains(where: { $0.pattern == "Unavailable" && conditionalsHold($0, ctx) })
        }
        // Unciv UnitPromotions.canBePromoted: "This Promotion is free" promotions can be taken without enough XP.
        guard promotionsAvailable(unit) > 0 else { return candidates.filter { $0.uniques.contains("This Promotion is free") } }
        return candidates
    }

    /// Unciv PromotionTree: the promotions to adopt, in order, to reach `name` (nil when adopted or unreachable), whether the
    /// shortest path is ambiguous, and the number of promoting steps needed
    func promotionPath(to name: String, for unit: Unit) -> (path: [String], ambiguous: Bool, distance: Int)? {
        let adopted = Set(unit.promotions)
        var possible = rs.promotions(forUnitType: unit.def.unitType)
        for p in unit.promotions where !possible.contains(where: { $0.name == p }) { if let d = rs.promotions[p] { possible.append(d) } }
        let names = possible.map { $0.name }
        let inTree = Set(names)
        var parents: [String: [String]] = [:], children: [String: [String]] = [:], unreachable: Set<String> = []
        let ctx = UniqueContext(civId: unit.civId, unit: unit)
        for p in possible {
            parents[p.name] = p.prerequisites.filter { inTree.contains($0) }
            for pre in parents[p.name]! { children[pre, default: []].append(p.name) }
            if !p.prerequisites.isEmpty && parents[p.name]!.isEmpty { unreachable.insert(p.name) }
            if p.uniqueObjects.contains(where: { $0.pattern == "Only available" && !conditionalsHold($0, ctx) }) { unreachable.insert(p.name) }
            if p.uniqueObjects.contains(where: { $0.pattern == "Unavailable" && conditionalsHold($0, ctx) }) { unreachable.insert(p.name) }
        }
        var depth: [String: Int] = [:], distance: [String: Int] = [:], ambiguous: [String: Bool] = [:], preferred: [String: String] = [:]
        for n in names where parents[n]!.isEmpty {
            depth[n] = 0; ambiguous[n] = false
            distance[n] = adopted.contains(n) ? 0 : unreachable.contains(n) ? Int.max : 1
        }
        for d in 0...99 {
            var complete = true
            for n in names {
                guard let nd = depth[n] else { complete = false; continue }
                if nd != d { continue }
                for child in children[n] ?? [] {
                    let dist = adopted.contains(child) ? 0 : (distance[n]! == Int.max || unreachable.contains(child)) ? Int.max : distance[n]! + 1
                    if depth[child] != nil {
                        if distance[child]! < dist { continue }
                        if distance[child]! == dist { ambiguous[child] = true; preferred[child] = nil; continue }
                    }
                    depth[child] = d + 1; distance[child] = dist
                    ambiguous[child] = ambiguous[n] ?? false
                    preferred[child] = (ambiguous[n] ?? false) ? nil : n
                }
            }
            if complete { break }
        }
        guard !adopted.contains(name), let target = distance[name], target != Int.max else { return nil }
        var path = [name], node = name
        while let p = preferred[node], !adopted.contains(p) { path.append(p); node = p }
        return (Array(path.reversed()), ambiguous[name] ?? false, target)
    }

    /// Unciv PromotionPickerScreen.getButton isPickable: movement left, an unambiguous (or one-step) path, and enough XP for its non-free promotions
    func canPickPromotionPath(_ info: (path: [String], ambiguous: Bool, distance: Int), for unit: Unit) -> Bool {
        unit.hasMovement && unit.attacksThisTurn == 0 && (!info.ambiguous || info.distance == 1) && canBuyPromotionPath(info, for: unit)
    }
    /// Unciv PromotionTree.canBuyUpTo: enough XP for the path's non-free promotions (the adopted check is the caller's)
    func canBuyPromotionPath(_ info: (path: [String], ambiguous: Bool, distance: Int), for unit: Unit) -> Bool {
        let nonFree = info.path.filter { !(rs.promotions[$0]?.uniques.contains("This Promotion is free") ?? false) }.count
        let available = promotionsAvailable(unit)
        return nonFree <= available && (available > 0 || nonFree == 0)
    }

    /// Unciv UnitPromotions.promotionCostModifier: the Float product of every "[]% XP required for promotions"
    /// `toPercent()` - (100 + x) / 100f - with no floor.
    func promotionXPModifier(_ civId: Int) -> Float { civUniques(civId).filter { $0.pattern == "[]% XP required for promotions" }.reduce(Float(1)) { $0 * (Float(100 + $1.double(0)) / 100) } }

    /// Unciv xpCostForPromotionNumber: `(number * 10 * promotionCostModifier()).toInt()`, in Float
    func xpCostForPromotionNumber(_ number: Int, civId: Int) -> Int { Int(Float(number * 10) * promotionXPModifier(civId)) }

    /// Unciv UnitPromotions.valueOfPromotionsAndXp: the promotions the unit would have with all its XP spent, plus
    /// `promotions.size - numberOfPromotions` "free" ones - not clamped, so a unit whose count exceeds its list (a
    /// promotion lost in an upgrade) scores below it - plus the Float progress towards the next one.
    func valueOfPromotionsAndXp(_ unit: Unit) -> Float {
        var n = unit.promotionNumber, rem = unit.currentXP
        while rem >= xpCostForPromotionNumber(n + 1, civId: unit.civId) { rem -= xpCostForPromotionNumber(n + 1, civId: unit.civId); n += 1 }
        let progress = Float(rem) / Float(xpCostForPromotionNumber(n + 1, civId: unit.civId))
        return Float(n + unit.promotions.count - unit.promotionNumber) + progress
    }

    func promotionsAvailable(_ unit: Unit) -> Int {
        var n = unit.promotionNumber, rem = unit.currentXP, k = 0
        while rem >= xpCostForPromotionNumber(n + 1, civId: unit.civId) { rem -= xpCostForPromotionNumber(n + 1, civId: unit.civId); n += 1; k += 1 }
        return k
    }

    /// Legacy saves stored lifetime XP: convert to Unciv's spendable XP and promotion count before changing either
    func migratePromotionState(_ i: Int) {
        guard units[i].numberOfPromotions == nil else { return }
        let n = units[i].promotionNumber
        units[i].xp = units[i].currentXP
        units[i].numberOfPromotions = n
    }

    func promote(unitId: Int, _ promotion: String) {
        guard let i = unitIndex(unitId), rs.promotions[promotion] != nil, availablePromotions(for: units[i]).contains(where: { $0.name == promotion }) else { return }
        addPromotion(unitId: unitId, promotion, isFree: false)
    }

    /// Unciv UnitPromotions.addPromotion, in its order: a bought promotion pays the next promotion's XP and counts
    /// (unless "This Promotion is free") and fires TriggerUponPromotion; every promotion then fires
    /// TriggerUponPromotionGain BEFORE it is added; it is kept unless it is a one-shot ("Doing so will consume this
    /// opportunity to choose a Promotion"), and then its direct effects run. We fired both triggers after the
    /// promotion was already on the unit. Promoting neither ends the turn nor heals. It ends, for every promotion,
    /// in updateUniques and updateVisibleTiles: a Sight promotion (Scouting, Sentry) widens the view at once.
    func addPromotion(unitId: Int, _ promotion: String, isFree: Bool) {
        guard let i = unitIndex(unitId), !units[i].promotions.contains(promotion), let def = rs.promotions[promotion] else { return }
        migratePromotionState(i)
        if !isFree {
            if !def.uniques.contains("This Promotion is free") {
                units[i].xp -= xpCostForPromotionNumber((units[i].numberOfPromotions ?? 0) + 1, civId: units[i].civId)
                units[i].numberOfPromotions = (units[i].numberOfPromotions ?? 0) + 1
            }
            if let u = unit(unitId) { triggerUnitConditionalUniques(unit: u) { $0.pattern == "upon being promoted" } }
        }
        if let u = unit(unitId) { triggerUnitConditionalUniques(unit: u) { $0.pattern == "upon gaining the [] promotion" && $0.param(0) == promotion } }
        guard let j = unitIndex(unitId) else { return }
        if def.isOneShot {
            // doDirectPromotionEffects of a promotion that is not kept
            triggerUniques(def.uniqueObjects, civId: units[j].civId, cityId: nil, unitId: unitId)
        } else {
            units[j].promotions.append(promotion)
            for u in def.uniqueObjects where u.pattern == "Can Spread Religion" { units[j].charges += u.conditional("[] additional time(s)")?.int(0) ?? 0 }
        }
        updateUnitUniquesCache(unitId)   // Unciv: `unit.updateUniques()`
        // Unciv: `unit.updateVisibleTiles()  // some promotions/uniques give the unit bonus sight`
        updateVisibleTilesAfterPromotionChange(unitId)
    }

    /// Unciv UnitPromotions.removePromotion: only a promotion the unit has; it goes, updateUniques and
    /// updateVisibleTiles run, and THEN TriggerUponPromotionLoss fires.
    func removePromotion(unitId: Int, _ promotion: String) {
        guard let i = unitIndex(unitId), units[i].promotions.contains(promotion) else { return }
        units[i].promotions.removeAll { $0 == promotion }
        updateUnitUniquesCache(unitId)
        updateVisibleTilesAfterPromotionChange(unitId)
        if let u = unit(unitId) { triggerUnitConditionalUniques(unit: u) { $0.pattern == "upon losing the [] promotion" && $0.param(0) == promotion } }
    }

    /// Unciv MapUnit.updateVisibleTiles as UnitPromotions calls it: the unit's stored view is recomputed and, when it
    /// changed and some tile of it lies outside ourTilesAndNeighboringTiles, civ.cache.updateViewableTiles runs -
    /// explored tiles, the invisible units seen, meeting civs - and ends in discoverNaturalWonders.
    func updateVisibleTilesAfterPromotionChange(_ unitId: Int) {
        guard revealFromCurrentTile(unitId), let u = unit(unitId) else { return }
        discoverNaturalWonders(civId: u.civId)
    }

    // MARK: upgrades

    /// Saves the unit's current promotions as the default for its kind in the city it stands in (or clears the flag).
    func setUseDefaultPromotions(unitId: Int, _ on: Bool) {
        guard let u = unit(unitId), let city = city(at: u.coord), city.civId == u.civId, let ci = cityIndex(city.id) else { return }
        if on { saveUnitPromotions(unitId: unitId, cityIndex: ci) }
        else { cities[ci].useDefaultPromotions.remove(u.name) }
    }

    /// Unciv PromotionPickerScreen.checkSaveUnitPromotion: `unitShouldUseSavedPromotion[name] = true;
    /// unitToPromotions[name] = unit.promotions` - the unit's own UnitPromotions, so the record stays live (SavedUnitPromotions).
    func saveUnitPromotions(unitId: Int, cityIndex ci: Int) {
        guard let u = unit(unitId), cities.indices.contains(ci) else { return }
        cities[ci].useDefaultPromotions.insert(u.name)
        cities[ci].defaultPromotions[u.name] = SavedUnitPromotions(promotions: u.promotions, xp: u.currentXP, numberOfPromotions: u.promotionNumber, unitId: u.id, unitName: u.name)
    }

    /// Unciv `city.unitToPromotions[name]` as it reads at this moment: the saving unit's promotions, XP and count while
    /// the record still points at that live MapUnit, else the record as it was frozen.
    func savedUnitPromotions(_ city: City, _ name: String) -> SavedUnitPromotions? {
        guard var saved = city.defaultPromotions[name] else { return nil }
        if let id = saved.unitId, let u = unit(id), u.name == saved.unitName {
            saved.promotions = u.promotions; saved.xp = u.currentXP; saved.numberOfPromotions = u.promotionNumber
        }
        return saved
    }

    /// The UnitPromotions object a record points at stops changing: WorldScreen.nextTurn's clone, an undo, a load
    /// (every record), or the saving unit's destruction or upgrade into a new MapUnit (`unitId`'s records only).
    func freezeSavedUnitPromotions(unitId: Int? = nil) {
        for ci in cities.indices where !cities[ci].defaultPromotions.isEmpty {
            for (name, saved) in cities[ci].defaultPromotions where saved.unitId != nil && (unitId == nil || saved.unitId == unitId) {
                guard var frozen = savedUnitPromotions(cities[ci], name) else { continue }
                frozen.unitId = nil; frozen.unitName = nil
                cities[ci].defaultPromotions[name] = frozen
            }
        }
    }

    /// Unciv PromotionTree(unit): possiblePromotions - the ruleset's promotions (in its order) for the unit's type or
    /// already adopted - sorted by row < 0 last, row 0 by column first, else column; then row; then the translated name
    /// with the locale's collator (a stable sort). allNodes() walks the same order.
    func promotionTreeOrder(for u: Unit) -> [String] {
        let adopted = Set(u.promotions)
        let possible = rs.promotionOrder.filter { $0.unitTypes.contains(u.def.unitType) || adopted.contains($0.name) }
        func key(_ p: PromotionDef) -> Int { p.row < 0 ? Int.max : p.row == 0 ? Int.min / 2 + p.column : p.column }
        return possible.enumerated().sorted { a, b in
            if key(a.element) != key(b.element) { return key(a.element) < key(b.element) }
            if a.element.row != b.element.row { return a.element.row < b.element.row }
            let r = LocaleCode.compare(L(a.element.name), L(b.element.name))
            return r == .orderedSame ? a.offset < b.offset : r == .orderedAscending
        }.map { $0.element.name }
    }

    /// Unciv CityConstructions.completeConstruction: a freshly built unit whose city uses the saved promotions for its
    /// kind - and whose XP is at least the saved record's - walks PromotionTree(unit).allNodes() order, adding each saved
    /// promotion that is possible for it (addPromotion: pays the XP, no prerequisite check) while its XP still covers
    /// the next promotion, stopping at the first node it cannot pay for.
    func applyDefaultPromotions(unitId: Int, city: City) {
        guard let u = unit(unitId) else { return }
        let treeOrder = promotionTreeOrder(for: u)
        let possiblePromotions = Set(treeOrder)
        guard city.useDefaultPromotions.contains(u.name), let saved = savedUnitPromotions(city, u.name), u.currentXP >= saved.xp else { return }
        let possiblePromotionFiltered = Set(saved.promotions.filter { possiblePromotions.contains($0) })
        for name in treeOrder {
            guard let now = unit(unitId) else { return }
            if now.currentXP - xpCostForPromotionNumber(now.promotionNumber + 1, civId: now.civId) >= 0 {   // XP - xpForNextPromotion()
                if possiblePromotionFiltered.contains(name) { addPromotion(unitId: unitId, name, isFree: false) }
            } else {
                break
            }
        }
    }
}
