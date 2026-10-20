// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's unit/UnitAutomation.kt.

extension GameState {
    // MARK: - movement helpers standing in for UnitMovement

    /// Unciv UnitMovement.getDistanceToTiles: tiles reachable this turn with the movement spent to get there (the unit's own tile left out)
    func distanceToTiles(_ unit: Unit) -> [HexCoord: Double] {
        guard !unit.def.isAir else { return [:] }
        let paths = turnPaths(unit)
        var out: [HexCoord: Double] = [:]
        for c in paths.order where c != unit.coord { out[c] = paths.nodes[c]!.total }
        return out
    }
    /// The reachable tiles in the order the movement search found them (Unciv iterates getDistanceToTiles in that order; first match wins ties)
    func reachableTilesInOrder(_ unit: Unit) -> [HexCoord] {
        guard !unit.def.isAir else { return [] }
        return turnPaths(unit).order.filter { $0 != unit.coord }
    }
    /// Unciv MapUnit.fortifyIfCan: `if (canFortify()) fortify()`, and canFortify() is false for a unit that is
    /// already fortified - "Fortify until healed" included, since isFortified() is `action.startsWith("Fortify")`.
    /// Ours set the order whatever it was, which turned a fortify-until-healed into a plain fortify, and let
    /// an embarked unit or one without a defensive terrain bonus fortify at all.
    func fortifyIfCan(_ unitId: Int) {
        guard let u = unit(unitId), canFortify(u), u.order != .fortify, u.order != .fortifyUntilHealed else { return }
        setOrder(unitId: unitId, .fortify)
    }

    // MARK: - UnitAutomation.automateUnitMoves

    static let closeEnemyTilesAwayLimit = 5
    static let closeEnemyTurnsAwayLimit = 3.0

    func automateUnitMoves(_ unitId: Int) {
        guard let unit = unit(unitId), civ(unit.civId)?.isBarbarian == false else { return }
        // With --trace-unit <Nation>/<UnitName> the branch each automation step takes is printed, which is the only
        // way to see why a unit that stands still in one engine walks in the other.
        let trace = epochsDebug && epochsTraceUnit == "\(civ(unit.civId)?.nation ?? "")/\(unit.name)"
        func T(_ k: String, _ body: () -> Bool) -> Bool {
            let r = AI.timedBool("u." + k, body)
            if trace {
                let here = self.unit(unitId)?.coord ?? unit.coord
                let cityHere = city(at: here).map { "\($0.name)\($0.coord == here ? "(center)" : "")" } ?? "-"
                let live = self.unit(unitId)
                print("TRACEU t=\(turn) \(unit.name) at \(uncivPosition(here)) hp=\(live?.health ?? -1) mp=\(live?.movementLeft ?? -1) city=\(cityHere) \(k)=\(r)")
            }
            return r
        }
        if damageFromTerrain(unit, at: unit.coord) > 0 && tryHealUnit(unitId) { return }
        if unit.isCivilian { var d: Set<HexCoord> = []; AI.timed("u.danger") { d = dangerousTilesForCivilian(unit) }; AI.timed("u.civilian") { automateCivilianUnit(unitId, dangerousTiles: d) }; return }
        // Unciv UnitAutomation.automateUnitMoves: `isHumanAndNotAutoplaying` - the AI promotes its units in
        // NextTurnAutomation.automateUnits and upgrades them in UseGoldAutomation, a human's automated unit does
        // both here (the upgrade only when "Automated units can upgrade" is on, which tryUpgradeUnit asks itself).
        let isHumanAndNotAutoplaying = civ(unit.civId)?.isPlayer == true && !autoPlaying   // UnitAutomation.kt:48-49: isAutoPlaying()
        if isHumanAndNotAutoplaying { applyPromotions(unitId); if GameState.evlogOn { hbr("S3.humanUnitPromotesUpgrades", unit.civId) } }
        if isHumanAndNotAutoplaying && tryUpgradeUnit(unitId) { return }
        // Military units with civilian abilities act as civilians in peace time. Unciv asks the unit's uniques -
        // BuildImprovements with ANY filter, so Rome's Legion ("Can build [Road] improvements on tiles") counts,
        // where our isWorker only matched the Worker's "[Land]".
        guard let unitNow = self.unit(unitId) else { return }
        if (unitHasUnique(unitNow, "Can build [] improvements on tiles") || unitHasUnique(unitNow, "Founds a new city") || unitHasUnique(unitNow, "Founds a new puppet city")
            || unitHasUnique(unitNow, "Religious Unit") || unitHasUnique(unitNow, "May create improvements on water resources")) && !isAtWarAtAll(unit.civId) {
            AI.timed("u.civilian") { automateCivilianUnit(unitId, dangerousTiles: dangerousTilesForCivilian(unitNow)) }; return
        }
        if unit.def.isNuclear { automateNukes(unitId); return }
        if unit.def.isAir {
            // Unciv MapUnit.canIntercept(): a chance above zero, movement and interceptions left this turn - asked of
            // the live unit, whose promotions a human's automation may just have picked.
            if canInterceptAtAll(unitNow) { automateFighter(unitId); return }
            // Unciv `unit.hasUnique(UniqueType.SelfDestructs)`: the MapUnit's uniques, its type's included - the
            // Guided Missile has it only on the Missile unit type, so ours sent it to automateBomber.
            if unitHasUnique(unitNow, "Self-destructs when attacking") { automateMissile(unitId); return }
            automateBomber(unitId); return
        }
        if T("accompany", { tryAccompanySettlerOrGreatPerson(unitId) }) { return }
        if T("ruin", { tryGoToRuin(unitId) }) && !(self.unit(unitId)?.hasMovement ?? false) { return }
        // Unciv reads `unit.health` and `unit.getTile()` live: the unit may just have walked into a ruin (and been
        // healed or moved by it), and the heal-here test is about the tile it stands on NOW, not where it started.
        guard let afterRuin = self.unit(unitId) else { return }
        if afterRuin.health < 50 && (T("retreat", { tryRetreat(unitId) }) || T("heal", { tryHealUnit(unitId) })) { return }
        if let u = self.unit(unitId), u.health < 100 && T("healHere", { canUnitHealInTurnsOnCurrentTile(u, turns: 2, noEnemyDistance: 3) }) { return }
        if T("sieged", { tryHeadTowardsOurSiegedCity(unitId) }) { return }
        if T("disembark", { tryDisembarkUnitToAttackPosition(unitId) }) { return }
        if T("attack", { tryAttacking(unitId) }) { return }
        if T("takeBack", { tryTakeBackCapturedCity(unitId) }) { return }
        if T("enemyCity", { tryHeadTowardsEnemyCity(unitId) }) { return }
        if T("encampment", { tryHeadTowardsEncampment(unitId) }) { return }
        if T("garrison", { tryGarrisoningLandUnit(unitId) }) { return }
        if let u = self.unit(unitId), u.health < 80, T("heal", { tryHealUnit(unitId) }) { return }
        if T("advance", { tryAdvanceTowardsCloseEnemy(unitId) }) { return }
        if let u = self.unit(unitId), u.health < 100, T("heal", { tryHealUnit(unitId) }) { return }
        if T("prepare", { tryPrepare(unitId) }) { return }
        if T("explore", { tryExplore(unitId) }) { return }
        if T("fogBust", { tryFogBust(unitId) }) { return }
        if civ(unit.civId)?.isCityState == true { wander(unitId, stayInTerritory: true) }
    }

    private func isGoodTileToExplore(_ unit: Unit, _ c: HexCoord, visibility: Int) -> Bool {
        guard let t = map[c], let civ = civ(unit.civId) else { return false }
        if let o = t.ownerCivId, self.civ(o)?.isCityState == true { return false }
        if !map.tilesWithin(c, radius: visibility).contains(where: { !civ.explored.contains($0) }) { return false }
        if civ.isCityState && !map.neighbors(of: c).contains(where: { map[$0]?.ownerCivId == unit.civId }) { return false }
        if damageFromTerrain(unit, at: c) > 0 { return false }
        if distanceToClosestEnemyUnit(c, civId: unit.civId, maxDist: 3) <= 3 { return false }   // Unciv getDistanceToClosestEnemyUnit(tile, 3) > 3
        return canUnitEnter(unit, c) && canReach(unit, c)
    }
    /// Unciv UnitAutomation.tryExplore
    func tryExplore(_ unitId: Int) -> Bool {
        if AI.timedBool("x.ruin", { tryGoToRuin(unitId) }) && !(unit(unitId)?.hasMovement ?? false) { return true }
        guard let unit = unit(unitId), let civ = civ(unit.civId) else { return false }
        // --trace-unit prints which of Unciv's two explore stages fired and what it aimed at. Comparing that line
        // against the reference's own is how the ship and the settler were both found.
        let trace = epochsDebug && epochsTraceUnit == "\(civ.nation)/\(unit.name)"
        // Unciv MapUnit.getVisibilityRange - the one function, not a second copy of the rule.
        let visibility = visibilityRange(of: unit)
        if trace {
            let parts: [String] = reachableTilesInOrder(unit).map { c in
                let t = map[c]!; let p = uncivPosition(c)
                let o = (t.ownerCivId.flatMap { self.civ($0) }?.isCityState == true) ? "O" : "o"
                let u = map.tilesWithin(c, radius: visibility).contains(where: { !civ.explored.contains($0) }) ? "u" : "U"
                let d = distanceToClosestEnemyUnit(c, civId: unit.civId, maxDist: 3)
                return "\(p.x),\(p.y):\(o)\(u)\(damageFromTerrain(unit, at: c))d\(d)\(canUnitEnter(unit, c) ? "m" : "M")\(canReach(unit, c) ? "r" : "R")"
            }
            print("EXPGE t=\(uncivTurns) " + parts.joined(separator: " "))
        }
        var thisTurn: [HexCoord] = []
        AI.timed("x.this") { thisTurn = reachableTilesInOrder(unit).filter { isGoodTileToExplore(unit, $0, visibility: visibility) } }
        if !thisTurn.isEmpty {
            let best = thisTurn.max { a, b in
                let sa = blockingHeight(map[a]!) + a.ring(radius: visibility).filter { $0.distance(to: a) == visibility && map.contains(map.normalize($0)) && !civ.explored.contains(map.normalize($0)) }.count
                let sb = blockingHeight(map[b]!) + b.ring(radius: visibility).filter { $0.distance(to: b) == visibility && map.contains(map.normalize($0)) && !civ.explored.contains(map.normalize($0)) }.count
                return sa < sb
            }!
            if trace {
                let u0 = uncivPosition(unit.coord), b = uncivPosition(best)
                let scored = thisTurn.map { a -> String in let p = uncivPosition(a); let c = a.ring(radius: visibility).filter { $0.distance(to: a) == visibility && map.contains(map.normalize($0)) && !civ.explored.contains(map.normalize($0)) }.count; return "\(p.x),\(p.y)=\(blockingHeight(map[a]!))+\(c)" }
                print("TRACEX t=\(turn) \(unit.name) at \(u0.x),\(u0.y) range=\(visibility) stage1 best=\(b.x),\(b.y) cands=\(scored)")
                let frame = UncivSave.Frame.forExport(width: map.width, height: map.height)
                for (ux, uy) in [(2, -13), (3, -12), (4, -11), (5, -10)] {
                    let g = frame.ours(x: ux, y: uy)
                    let c = HexCoord.fromOffset(col: g.col, row: g.row)
                    print("TRACEX2 \(ux),\(uy) -> \(c) inMap=\(map.contains(map.normalize(c))) explored=\(civ.explored.contains(map.normalize(c)))")
                }
            }
            moveUnit(unitId, toward: best); return true
        }
        if trace {
            let tr = map.tilesWithin(unit.coord, radius: 5).filter { c in
                guard let t = map[c] else { return false }
                return !(t.ownerCivId.flatMap { self.civ($0) }?.isCityState ?? false) && map.tilesWithin(c, radius: visibility).contains(where: { !civ.explored.contains($0) }) }
            print("TRACEXE t=\(uncivTurns) stage2 unexploredNear=" + tr.map { c in let p = uncivPosition(c); let un = map.tilesWithin(c, radius: visibility).filter { !civ.explored.contains($0) }.map { let q = uncivPosition($0); return "\(q.x),\(q.y)@\($0)" }.joined(separator: "/")
                return "\(p.x),\(p.y)[\(un)]:d\(distanceToClosestEnemyUnit(c, civId: unit.civId, maxDist: 3))\(damageFromTerrain(unit, at: c) <= 0 ? "" : "D")\(canUnitEnter(unit, c) ? "m" : "M")\(canReach(unit, c) ? "r" : "R")" }.joined(separator: " "))
        }
        var fallback: HexCoord? = nil
        AI.timed("x.fallback") { fallback = map.tilesWithin(unit.coord, radius: 5).first { isGoodTileToExplore(unit, $0, visibility: visibility) } }
        if let c = fallback {
            // canReach is our own connectivity shortcut; Unciv's is getShortestPath().any(). When the shortcut
            // says yes and the path search says there is none, the unit is sent to a tile it cannot walk to and
            // stands still for the turn - so the trace prints both answers side by side.
            if trace { let u0 = uncivPosition(unit.coord), p = uncivPosition(c); print("TRACEX t=\(turn) \(unit.name) at \(u0.x),\(u0.y) range=\(visibility) stage2 target=\(p.x),\(p.y) pathLen=\(shortestPath(unit, to: c).count) owner=\(map[c]?.ownerCivId.flatMap { self.civ($0)?.nation } ?? "-") pass=\(map[c]?.ownerCivId.map { canPassThroughTiles(unit.civId, $0) } ?? true) open=\(map[c]?.ownerCivId.map { hasOpenBorders(unit.civId, in: $0) } ?? false) war=\(map[c]?.ownerCivId.map { areAtWar(unit.civId, $0) } ?? false)") }
            AI.timed("x.move") { _ = moveUnit(unitId, toward: c) }; return true
        }
        if trace { let u0 = uncivPosition(unit.coord); print("TRACEX t=\(turn) \(unit.name) at \(u0.x),\(u0.y) range=\(visibility) none") }
        if trace, let want = ProcessInfo.processInfo.environment["PROBE_EXPL"] {
            let xy = want.split(separator: ",").compactMap { Int($0) }
            if xy.count == 2, let c = map.tilesWithin(unit.coord, radius: 5).first(where: { let p = uncivPosition($0); return p.x == xy[0] && p.y == xy[1] }), let t = map[c] {
                let unexplored = map.tilesWithin(c, radius: visibility).filter { !civ.explored.contains($0) }.map { let p = uncivPosition($0); return "\(p.x),\(p.y)" }
                print("PROBEX t=\(turn) \(want) owner=\(t.ownerCivId.flatMap { self.civ($0)?.nation } ?? "-") unexpl=\(unexplored) dmg=\(damageFromTerrain(unit, at: c)) enemy=\(distanceToClosestEnemyUnit(c, civId: unit.civId, maxDist: 3)) canMove=\(canUnitEnter(unit, c)) canReach=\(canReach(unit, c)) pass=\(canPassThrough(unit, c)) civPass=\(t.ownerCivId.map { canPassThroughTiles(unit.civId, $0) } ?? true) open=\(t.ownerCivId.map { hasOpenBorders(unit.civId, in: $0) } ?? false) units=\(units(at: c).map { "\(self.civ($0.civId)?.nation ?? "?")/\($0.name)" }) escort=\(isEscorting(unit))")
            }
        }
        return false
    }
    private func tryGoToRuin(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId), civ(unit.civId)?.isMajor == true else { return false }
        // Unciv `unit.viewableTiles.firstOrNull { ... }`: viewableTiles is a HashSet<Tile>, and under the reference's
        // identity hash 1 it walks as JavaHash1Set does over the list it was built from - not nearest first. Ours
        // sorted by distance and then (q, r), a tie-break Unciv does not have.
        let ruin = unitViewableTilesUncivOrder(unit).first { map[$0]?.hasRuins == true && canUnitEnter(unit, $0) && canReach(unit, $0) }
        guard let r = ruin else { return false }
        moveUnit(unitId, toward: r)
        return true
    }
    /// Unciv MapUnit.viewableTiles in its HashSet walk: `hashSetOf(tile)` for "No Sight",
    /// `getTilesInDistance(range).toHashSet()` (a Sequence: default capacity) for "Can see over obstacles",
    /// else `getViewableTilesList(range).toHashSet()` (a List: Kotlin's collection capacity).
    func unitViewableTilesUncivOrder(_ u: Unit) -> [HexCoord] {
        if u.promotionUniques.contains(where: { $0.pattern == "No Sight" }) { return [u.coord] }
        let radius = visibilityRange(of: u, civSight: civUniques(u.civId).filter { $0.pattern == "[] Sight" })
        let overObstacles = u.def.uniques.contains("Can see over obstacles") || (rs.unitTypes[u.def.unitType]?.uniques.contains("Can see over obstacles") ?? false)
        if overObstacles { return JavaHash1Set.iterationOrder(map.tilesWithin(u.coord, radius: radius)) }
        let list = viewableTilesList(from: u.coord, radius: radius, viewerBonus: 0)
        return JavaHash1Set.iterationOrder(list, initialCapacity: JavaHash1Set.kotlinCollectionCapacity(list.count))
    }
    /// Unciv UnitAutomation.tryFogBust
    private func tryFogBust(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId), afraidOfBarbarians(unit.civId) else { return false }
        let vis = visibleTiles(for: unit.civId)
        if map.tilesWithin(unit.coord, radius: 5).allSatisfy({ vis.contains($0) }) { return false }
        // Unciv UnitAutomation.kt:184: `unit.cache.state.stateBasedRandom("UnitAutomation.tryFogBust")`
        var g = stateBasedRandom("UnitAutomation.tryFogBust", unit: unit)
        // Unciv `getDistanceToTiles().keys.filter { .. }.random(rng)`: the draw indexes the LinkedHashMap's order,
        // the order the movement search found the tiles - ours drew from a (q, r) sort of it.
        let thisTurn = reachableTilesInOrder(unit).filter { isGoodTileForFogBusting(unit, $0) }
        if let pick = g.pick(thisTurn) { moveUnit(unitId, toward: pick); return true }
        for c in map.tilesWithin(unit.coord, radius: 5) where isGoodTileForFogBusting(unit, c) { moveUnit(unitId, toward: c); return true }
        return false
    }
    private func isGoodTileForFogBusting(_ unit: Unit, _ c: HexCoord) -> Bool {
        guard let t = map[c], let civ = civ(unit.civId) else { return false }
        return canUnitEnter(unit, c) && t.ownerCivId == nil && map.neighbors(of: c).allSatisfy { map[$0]?.ownerCivId == nil } && civ.explored.contains(c)
            && map.tilesWithin(c, radius: 2).contains { map[$0]?.ownerCivId == unit.civId } && damageFromTerrain(unit, at: c) <= 0 && canReach(unit, c)
    }
    /// Unciv UnitAutomation.wander
    func wander(_ unitId: Int, stayInTerritory: Bool = false, tilesToAvoid: Set<HexCoord> = []) {
        guard let unit = unit(unitId), unit.hasMovement else { return }
        // Unciv `unit.currentTile.getTilesAtDistance(1)`: the ring from 6 o'clock, each tile paired with its mirror -
        // not the neighbour order - and the random pick below indexes into exactly this list.
        // Unciv canReachInCurrentTurn: getDistanceToTiles().containsKey(tile) (only its own tile for a unit that cannot move)
        let paths: TurnPaths? = unitCannotMove(unit) ? nil : turnPaths(unit)
        let reachable = map.tilesInDistanceUncivOrder(unit.coord, radius: 1).filter { $0.distance(to: unit.coord) == 1 }.filter { c in
            !tilesToAvoid.contains(c) && canMoveTo(unit, c) && (paths?.contains(c) ?? (c == unit.coord)) && damageFromTerrain(unit, at: c) <= 0
                && (!stayInTerritory || map[c]?.ownerCivId == unit.civId || map[unit.coord]?.ownerCivId != unit.civId)
        }
        // Unciv UnitAutomation.kt:225: `unit.cache.state.stateBasedRandom("UnitAutomation.wander")`
        if epochsWanderDbg {
            let ctx = UniqueContext(civId: unit.civId, unit: unit, tile: map[unit.coord])
            print("WDBG t=\(uncivTurns) \(civ(unit.civId)?.nation ?? "-") \(unit.name) \(evPos(unit.coord)) mv=\(Float(unit.movementLeft)) rt=\(evPos(unit.coord)) rc=\(relevantCity(ctx)?.name ?? "null") h=\(contextHash(ctx)) reach=\(reachable.map { evPos($0) }.joined(separator: " "))")
        }
        var g = stateBasedRandom("UnitAutomation.wander", unit: unit)
        // Unciv `unit.movement.moveToTile(...)`, not headTowards
        if let pick = g.pick(reachable) { moveToTile(unitId, pick) }
    }
    /// Unciv UnitAutomation.tryUpgradeUnit
    @discardableResult
    /// Unciv UnitAutomation.tryUpgradeUnit: the cheapest valid upgrade; new resource types need allowSpendingResource
    func tryUpgradeUnit(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId) else { return false }
        // `if (unit.civ.isHuman() && !settings.automatedUnitsCanUpgrade && worldScreen?.autoPlay?.isAutoPlayingAndFullAutoPlayAI()
        // == false) return false` - in the function, so UseGoldAutomation's upgrades of an automated human ask it too (ours
        // asked only at automateUnitMoves' call: a human under AutoPlay without fullAutoPlayAI paid for upgrades Unciv's
        // never bought). With no world screen (`?.` gives null, not false) the setting does not stop it.
        if civ(unit.civId)?.isPlayer == true && !UserSettings.automatedUnitsCanUpgrade && !epochsAutoplay && !autoPlayingFullAI { return false }
        let ctx = UniqueContext(civId: unit.civId, unit: unit, tile: map[unit.coord])
        // Unciv getUnitsToUpgradeTo: `baseUnit.getRulesetUpgradeUnits(state)` - upgradesTo FIRST, then the
        // "Can upgrade to []" uniques - each as the civ's equivalent unit. `minBy { cost }` keeps the first of
        // equal costs, so the order is the tie-break (the unit panel's order is the other way round).
        var names: [String] = []
        if let base = unit.def.upgradesTo { names.append(base) }
        names += unit.def.uniqueObjects.filter { $0.pattern == "Can upgrade to []" && conditionalsHold($0, ctx) }.map { $0.param(0) }
        let barbarian = civ(unit.civId)?.isBarbarian == true   // Unciv: CannotBeBarbarian targets are not offered to barbarians
        let options = names.compactMap { rs.units[$0] }.map { equivalentUnit(unit.civId, $0) }.filter { t in
            !(barbarian && t.neverBarbarian)
                && !t.uniqueObjects.contains { $0.pattern == "Only available" && !conditionalsHold($0, ctx) } && !t.uniqueObjects.contains { $0.pattern == "Unavailable" && conditionalsHold($0, ctx) } && unitCanUpgrade(unit, to: t)
        }
        guard let target = options.min(by: { $0.cost < $1.cost }) else { return false }
        let current = resourceRequirementsPerTurn(requiredResource: unit.def.requiredResource, uniques: unit.def.uniqueObjects, ctx: ctx)
        let needed = resourceRequirementsPerTurn(requiredResource: target.requiredResource, uniques: target.uniqueObjects, ctx: ctx)
        if needed.keys.contains(where: { current[$0] == nil }) && !allowSpendingResource(unit.civId, unit: target, building: nil) { return false }
        return upgradeUnit(unitId, to: target)
    }
    /// Unciv UnitAutomation.tryAttacking – true only if the unit has no movement left.
    private func tryAttacking(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId) else { return false }
        let attacks = 1 + extraAttacks(of: unit) - unit.attacksThisTurn
        for _ in 0..<max(0, attacks) {
            if tryAttackNearbyEnemy(unitId) { return true }
            if let u = self.unit(unitId), u.health < 50, tryRetreat(unitId) { return true }
        }
        return false
    }
    private func tryHeadTowardsEncampment(_ unitId: Int) -> Bool {
        // Unciv `if (unit.hasUnique(UniqueType.SelfDestructs)) return false` - the MapUnit's uniques, its type's included
        guard let unit = unit(unitId), !unitHasUnique(unit, "Self-destructs when attacking"), let civ = civ(unit.civId) else { return false }
        let myCities = cities(of: unit.civId)
        // Unciv builds this list as `cities.flatMap { it.getCenterTile().getTilesInDistance(6) }
        // .filter { it.isBarbarianEncampment() && unit.civ.hasExplored(it) }.distinct()` - city order, then
        // ring order inside each city, then dedup. Ours walked the global `encampments` array instead, which
        // is a different order entirely, so a tie-break alone would only have frozen the wrong one.
        var seenCamp: Set<HexCoord> = []
        let camps = myCities.flatMap { map.tilesWithin($0.coord, radius: 6) }
            .filter { c in map[c]?.hasBarbarianCamp == true && civ.explored.contains(c) }
            .filter { seenCamp.insert($0).inserted }
        let sorted = camps.enumerated().sorted { ($0.element.distance(to: unit.coord), $0.offset) < ($1.element.distance(to: unit.coord), $1.offset) }.map { $0.element }   // Unciv sortedBy, stable
        guard let target = sorted.first(where: { canReach(unit, $0) }) else { return false }
        moveUnit(unitId, toward: target)
        return true
    }
    /// Unciv UnitAutomation.tryRetreat
    func tryRetreat(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId), unit.isMilitary, !unit.def.isAir else { return false }
        if distanceToClosestEnemyUnit(unit.coord, civId: unit.civId, maxDist: 4) > 3 { return false }
        let dist = distanceToTiles(unit)
        let closestCity = cities(of: unit.civId).min { $0.coord.distance(to: unit.coord) < $1.coord.distance(to: unit.coord) }.flatMap { $0.coord.distance(to: unit.coord) < 20 ? $0 : nil }
        let sortedTiles: [HexCoord]
        // Unciv sorts `getDistanceToTiles()` with sortedBy / sortedByDescending - stable, and its source is
        // a LinkedHashMap, so the pathfinder's own BFS order breaks every tie. `reachableTilesInOrder` is
        // that order here; the sort just has to stop shuffling it.
        if let cc = closestCity { sortedTiles = reachableTilesInOrder(unit).enumerated().sorted { ($0.element.distance(to: cc.coord), $0.offset) < ($1.element.distance(to: cc.coord), $1.offset) }.map { $0.element } }
        else { sortedTiles = reachableTilesInOrder(unit).enumerated().sorted { a, b in
                 let x = distanceToClosestEnemyUnit(a.element, civId: unit.civId, maxDist: 3, takeLargerValues: false)
                 let y = distanceToClosestEnemyUnit(b.element, civId: unit.civId, maxDist: 3, takeLargerValues: false)
                 return (-x, a.offset) < (-y, b.offset)
               }.map { $0.element } }
        let ourDistance = distanceToClosestEnemyUnit(unit.coord, civId: unit.civId, maxDist: 4, takeLargerValues: false)
        for retreat in sortedTiles {
            let tileDistance = distanceToClosestEnemyUnit(retreat, civId: unit.civId, maxDist: 4, takeLargerValues: false)
            if ourDistance >= tileDistance { continue }
            // Unciv `retreatTile.militaryUnit`: aircraft are not the tile's military unit
            if let other = militaryUnitOn(retreat) {
                // The tile is taken, lets see if we want to swap retreat to it
                guard other.civId == unit.civId else { continue }
                if other.health <= 80 { continue }
                // Don't swap ranged units closer than they have to be
                if other.def.isRanged && ourDistance < other.def.range { continue }
                // Unciv UnitMovement.canUnitSwapTo itself - ours spelled out a looser copy of it
                guard canUnitSwapTo(unit, retreat) else { continue }
                headTowards(unitId, retreat)   // we need to move through the intermediate tiles
                // if nothing changed
                if let u = self.unit(unitId), let o = self.unit(other.id), map.neighbors(of: u.coord).contains(o.coord), canUnitSwapTo(u, retreat) {
                    swapMoveToTile(unitId, retreat)
                }
                return true
            } else {
                // See if we can retreat to the tile
                guard canMoveTo(unit, retreat) else { continue }
                moveToTile(unitId, retreat)
                return true
            }
        }
        return false
    }
    /// Unciv UnitAutomation.tryHealUnit
    func tryHealUnit(_ unitId: Int) -> Bool {
        guard let unit0 = unit(unitId) else { return false }
        if unit0.def.isRanged && unit0.promotionUniques.contains(where: { $0.pattern == "Unit will heal every turn, even if it performs an action" }) { return false }
        while tryPillageImprovement(unitId, onlyPillageToHeal: true) {
            guard let u = unit(unitId) else { return true }
            if !u.hasMovement || u.health == 100 { return !u.hasMovement }
        }
        guard let unit = unit(unitId) else { return true }
        // Unciv `if (unitDistanceToTiles.isEmpty()) return true` never fires: getDistanceToTiles always holds the
        // unit's own tile. Ours left that tile out, so a unit with no movement returned here - before the
        // heal-here test and before the no-healing-tile branch Unciv goes on to.
        let dangerous = dangerousTiles(for: unit, distance: 3)
        // If the unit can heal on this tile in two turns, just heal here
        if !dangerous.contains(unit.coord) && canUnitHealInTurnsOnCurrentTile(unit, turns: 3) { return true }
        // Unciv: viableTilesForHealing comes from getDistanceToTiles (its own tile too, which canMoveTo refuses)
        let order = reachableTilesInOrder(unit)
        let viable = order.filter { !dangerous.contains($0) && canMoveTo(unit, $0) }
        let rated = Dictionary(grouping: viable, by: { rankTileForHealing(unit, $0) })
        if rated.keys.allSatisfy({ $0 == 0 }) { // We can't heal here at all! We're probably embarked
            if !unit.def.isAir {
                if let cityTile = cities(of: unit.civId).map({ $0.coord }).enumerated().sorted(by: { ($0.element.distance(to: unit.coord), $0.offset) < ($1.element.distance(to: unit.coord), $1.offset) }).map({ $0.element }).first(where: { canReach(unit, $0) }) { headTowards(unitId, cityTile) }
                else { wander(unitId) }
                return true
            }
            // Try to get closer to an empty city
            let emptyCities = cities(of: unit.civId).map { $0.coord }.filter { canMoveTo(unit, $0) }
            if emptyCities.isEmpty { return false } // Nowhere to move to heal
            // Unciv `unitDistanceToTiles.keys.filter { .. }.minByOrNull { .. }`: the first of equal distances in the
            // order the movement search found them.
            guard let next = order.filter({ canMoveTo(unit, $0) }).min(by: { a, b in emptyCities.map { $0.distance(to: a) }.min()! < emptyCities.map { $0.distance(to: b) }.min()! }) else { return false }
            moveToTile(unitId, next); return true
        }
        let bestRate = rated.keys.max()!
        let bestTiles = rated[bestRate]!
        // Unciv `maxByOrNull { it.getDefensiveBonus(unit = unit) }` - a Float, first of equal values
        let bestTile = bestTiles.max { Float(map[$0]?.defenceBonus ?? 0) < Float(map[$1]?.defenceBonus ?? 0) }!
        if unit.coord != bestTile && bestRate > rankTileForHealing(unit, unit.coord) - damageFromTerrain(unit, at: unit.coord) { moveToTile(unitId, bestTile) }
        fortifyIfCan(unitId)
        return true
    }
    /// Unciv UnitAutomation.canUnitHealInTurnsOnCurrentTile
    func canUnitHealInTurnsOnCurrentTile(_ unit: Unit, turns: Int, noEnemyDistance: Int = 3) -> Bool {
        if unit.promotionUniques.contains(where: { $0.pattern == "Unit will heal every turn, even if it performs an action" }) { return false }
        if epochsDebug, epochsTraceUnit == "\(civ(unit.civId)?.nation ?? "")/\(unit.name)" {
            let p = uncivPosition(unit.coord)
            let near = map.tilesWithin(unit.coord, radius: noEnemyDistance).filter { t in units(at: t).contains { $0.isMilitary && areAtWar(unit.civId, $0.civId) } }
            let live = near.map { t -> String in let q = uncivPosition(t); return "\(q.x),\(q.y):" + units(at: t).map { "\(civ($0.civId)?.nation ?? "?").\($0.name) vis=\(visibleTiles(for: unit.civId).contains(t)) inv=\(viewableInvisibleUnitsTiles(unit.civId)[t].map { Array($0).sorted().joined(separator: "|") } ?? "-") see=\(canSeeInvisibleUnit($0, from: unit.civId))" }.joined(separator: "/") }
            print("HEALPRE t=\(uncivTurns) at \(p.x),\(p.y) enemyDist=\(distanceToClosestEnemyUnit(unit.coord, civId: unit.civId, maxDist: noEnemyDistance)) live=\(live)")
        }
        // Unciv `unit.getTile().isCityCenter() && unit.getTile().getCity()!!.health > 50` - whose city it is is not asked
        let safeCity = city(at: unit.coord).map { $0.health > 50 } ?? false
        if !safeCity && distanceToClosestEnemyUnit(unit.coord, civId: unit.civId, maxDist: noEnemyDistance) <= noEnemyDistance { return false }
        let required = Int(ceil(Double(100 - unit.health) / Double(turns)))
        if epochsDebug, epochsTraceUnit == "\(civ(unit.civId)?.nation ?? "")/\(unit.name)" {
            let p = uncivPosition(unit.coord)
            print("HEALE t=\(uncivTurns) at \(p.x),\(p.y) req=\(required) rank=\(rankTileForHealing(unit, unit.coord)) friendly=\(isFriendlyTerritory(unit.coord, for: unit.civId)) owner=\(map[unit.coord]?.ownerCivId.flatMap { civ($0)?.nation } ?? "-") water=\(map[unit.coord]?.isWater ?? false) enemy=\(distanceToClosestEnemyUnit(unit.coord, civId: unit.civId, maxDist: noEnemyDistance))")
        }
        return required <= rankTileForHealing(unit, unit.coord)
    }
    /// Unciv UnitAutomation.tryPillageImprovement
    @discardableResult
    func tryPillageImprovement(_ unitId: Int, onlyPillageToHeal: Bool = false) -> Bool {
        guard let unit = unit(unitId), unit.isMilitary else { return false }
        let dist = distanceToTiles(unit)
        // Unciv: tiles reachable with movement to spare that the unit can move to (so never its own tile) and may pillage
        let unableToPillage = unit.def.uniques.contains("Unable to pillage tiles") || (unit.promotionUniques + civUniques(unit.civId)).contains { $0.pattern == "Unable to pillage tiles" }
        // Unciv getDistanceToTiles holds the unit's own tile at totalMovement 0, so it may pillage where it stands
        let candidates = ([unit.coord] + reachableTilesInOrder(unit)).filter { Float($0 == unit.coord ? 0 : (dist[$0] ?? .infinity)) < Float(unit.movementLeft) }.filter { c in
            // Unciv UnitActionsPillage.canPillage: not while transported, a pillageable tile, no CannotPillage, and the owner (if any) at war
            guard !unableToPillage, !unit.isTransported, let t = map[c], canMoveTo(unit, c), t.canPillageTile, t.ownerCivId.map({ areAtWar(unit.civId, $0) }) ?? true else { return false }
            // Unciv Tile.getRoadOwner(): `roadOwnerObject ?: getOwner()` - who built the road first, the tile's owner
            // only when nobody is recorded. Ours asked the owner first.
            return t.canPillageImprovement || (!onlyPillageToHeal && t.canPillageRoad && ((t.roadOwner ?? t.ownerCivId).map { areAtWar(unit.civId, $0) } ?? false))
        }
        if epochsDebug, epochsTraceUnit == "\(civ(unit.civId)?.nation ?? "")/\(unit.name)" {
            print("TRACEP2 t=\(turn) at=\(uncivPosition(unit.coord)) mp=\(unit.movementLeft) order=" + ([unit.coord] + reachableTilesInOrder(unit)).map { c in let q = uncivPosition(c); return "\(q.x),\(q.y)=\(c == unit.coord ? 0 : (dist[c] ?? -1))\(candidates.contains(c) ? "*" : "")" }.joined(separator: " "))
            for c in reachableTilesInOrder(unit) where (dist[c] ?? .infinity) < unit.movementLeft && !candidates.contains(c) {
                guard let t = map[c] else { continue }
                let q = uncivPosition(c)
                print("TRACEP3 \(q.x),\(q.y) units=\(units(at: c).map { "\(civ($0.civId)?.nation ?? "")/\($0.name)" }) enter=\(canUnitEnter(unit, c)) pill=\(t.canPillageTile) imp=\(t.canPillageImprovement) owner=\(t.ownerCivId.map { civ($0)?.nation ?? "" } ?? "-")")
            }
        }
        guard !candidates.isEmpty else { return false }
        // Unciv `maxByOrNull { it.getDefensiveBonus(false, unit) }` - a Float, first of equal values
        let target = candidates.max { Float(map[$0]?.defenceBonusWithoutImprovement ?? 0) < Float(map[$1]?.defenceBonusWithoutImprovement ?? 0) }!
        if unit.coord != target { moveToTile(unitId, target) }   // Unciv moveToTile
        guard let u = self.unit(unitId), u.coord == target else { return false }
        // Unciv `getPillageAction(unit, unit.currentTile)?.action?.invoke(); return true` - true once the unit
        // stands there, whether or not the action was available (pillage() checks that itself)
        pillage(unitId: unitId)
        return true
    }
    /// Unciv UnitAutomation.tryAdvanceTowardsCloseEnemy
    private func tryAdvanceTowardsCloseEnemy(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId) else { return false }
        if !anyEnemyWithin(unit.coord, civId: unit.civId, dist: GameState.closeEnemyTilesAwayLimit + attackRange(unit)) { return false }
        // Unciv: getMovementToTilesAtPosition with the maximum movement times CLOSE_ENEMY_TURNS_AWAY_LIMIT
        var caches = MoveCaches()
        let paths = movementToTiles(unit, moveContext(for: unit), at: unit.coord, movement: maxMovement(of: unit) * GameState.closeEnemyTurnsAwayLimit, caches: &caches)
        var reach: [HexCoord: Double] = [:]
        for c in paths.order where c != unit.coord { reach[c] = paths.nodes[c]!.total }
        let scope = map.tilesWithin(unit.coord, radius: GameState.closeEnemyTilesAwayLimit)
        // Unciv sorts THIS map's entries (stable, by totalMovement): equal totals keep the order this wider search
        // found them in, which is not always the order of the one-turn search.
        let close = attackableEnemies(unit, distanceToTiles: reach, tilesToCheck: scope, order: paths.order)
            .filter { !(unit.def.isRanged && (city(at: $0.tileToAttack)?.health ?? 0) == 1) }
            .filter { damageFromTerrain(unit, at: $0.tileToAttackFrom) <= 0 }
            .filter { damageToAttacker(unit, from: unit.coord, target: $0.tileToAttack) < unit.health }
            .min { $0.tileToAttack.distance(to: unit.coord) < $1.tileToAttack.distance(to: unit.coord) }
        if epochsDebug, epochsTraceUnit == "\(civ(unit.civId)?.nation ?? "")/\(unit.name)" {
            let all = attackableEnemies(unit, distanceToTiles: reach, tilesToCheck: scope)
            let parts: [String] = all.map { a in let t = uncivPosition(a.tileToAttack), f = uncivPosition(a.tileToAttackFrom); return "\(t.x),\(t.y)<-\(f.x),\(f.y):d\(a.tileToAttack.distance(to: unit.coord)):\(units(at: a.tileToAttack).map { "\(civ($0.civId)?.nation ?? "?")/\($0.name)" })" }
            print("TRACEA t=\(turn) \(unit.name) n=\(all.count) " + parts.joined(separator: " "))
            for a in all {
                let seers: [String] = units(of: unit.civId).filter { map.tilesWithin($0.coord, radius: visibilityRange(of: $0)).contains(a.tileToAttack) }.map { u in let p = uncivPosition(u.coord); return "\(u.name)@\(p.x),\(p.y)/r\(visibilityRange(of: u))" }
                print("TRACEV t=\(turn) visible=\(visibleTiles(for: unit.civId).contains(a.tileToAttack)) myRange=\(visibilityRange(of: unit)) seers=\(seers) cities=\(cities(of: unit.civId).filter { $0.coord.distance(to: a.tileToAttack) <= 3 }.map { $0.name })")
            }
        }
        if let c = close { moveUnit(unitId, toward: c.tileToAttackFrom); return true }
        return false
    }
    /// Unciv UnitAutomation.tryPrepare: move to our city closest to a hostile civ.
    private func tryPrepare(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId), civ(unit.civId) != nil else { return false }
        func hasPreparationFlag(_ other: Int) -> Bool {
            if hasFlag(unit.civId, other, "Denunciation") || hasFlag(other, unit.civId, "Denunciation") { return true }
            if hasFlag(unit.civId, other, "WaryOf") && flag(unit.civId, other, "WaryOf") < 0 { return true }
            return false
        }
        let hostile = Set(knownCivs(unit.civId).filter { areAtWar(unit.civId, $0.id) || hasPreparationFlag($0.id) }.map { $0.id })
        let closeCities = neighboringCitiesOfOtherCivs(unit.civId).filter { hostile.contains($0.1.civId) }
        if epochsDebug, epochsTraceUnit == "\(civ(unit.civId)?.nation ?? "")/\(unit.name)" {
            print("TRACEP t=\(turn) \(unit.name) hostile=[\(hostile.compactMap { civ($0)?.nation }.sorted().joined(separator: ","))] close=\(closeCities.count) known=\(knownCivs(unit.civId).count) neigh=\(neighboringCitiesOfOtherCivs(unit.civId).count)")
        }
        guard let closest = closeCities.map({ $0.0.coord.distance(to: $0.1.coord) }).min() else { return false }
        var seen: Set<Int> = []
        let toDefend = closeCities.filter { $0.0.coord.distance(to: $0.1.coord) <= closest + 2 }.map { $0.0 }.filter { seen.insert($0.id).inserted }
            .enumerated().sorted { ($0.element.coord.distance(to: unit.coord), $0.offset) < ($1.element.coord.distance(to: unit.coord), $1.offset) }.map { $0.element }   // Unciv sortedBy, stable
        for city in toDefend {
            if unit.coord.distance(to: city.coord) <= 2 { return true }
            if let t = map.tilesWithin(city.coord, radius: 2).first(where: { canUnitEnter(unit, $0) && canReach(unit, $0) }) { moveUnit(unitId, toward: t); return true }
        }
        return false
    }
    private func tryAccompanySettlerOrGreatPerson(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId) else { return false }
        let dist = distanceToTiles(unit)
        let target = units(of: unit.civId).first { other in
            other.isCivilian && (other.def.isSettler || other.isGreatPerson) && !other.def.hasStrengthBonusInRadius
                && (other.coord == unit.coord || (militaryUnitOn(other.coord) == nil && canMoveTo(unit, other.coord))) && (other.coord == unit.coord || dist[other.coord] != nil)
        }
        guard let t = target else { return false }
        moveUnit(unitId, toward: t.coord)
        return true
    }
    private func tryHeadTowardsOurSiegedCity(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId) else { return false }
        let sieged = cities(of: unit.civId).filter { $0.health < cityMaxHealth($0) }
        if sieged.contains(where: { $0.coord.distance(to: unit.coord) <= 2 }) { return false }
        // Unciv: `siegedCities.flatMap { it.getCenterTile().getTilesAtDistance(2) }.sortedBy { aerialDistanceTo(unit) }`.
        // Two things ours got wrong. `HexCoord.ring(radius:)` returns the whole DISK, not the ring at exactly
        // that distance, so tiles right next to the besieged city were candidates Unciv never considers. And
        // Kotlin's `sortedBy` is stable while Swift's `sorted(by:)` is not, so equal distances were ordered by
        // the run. Measured on `settled` turn 52: Byzantium's Warrior walked to -1,-6 - inside Japan's borders -
        // where Unciv's walked to -2,-7. That tile is one Kyoto was working, and an enemy military unit standing
        // on it blockades it, so Kyoto dropped a citizen to four worked tiles where Unciv kept five.
        let ringTiles = sieged.flatMap { c in map.tilesInDistanceUncivOrder(c.coord, radius: 2).filter { $0.distance(to: c.coord) == 2 } }
        let target = ringTiles.enumerated()
            .sorted { ($0.element.distance(to: unit.coord), $0.offset) < ($1.element.distance(to: unit.coord), $1.offset) }
            .map { $0.element }
            .first { canUnitEnter(unit, $0) && canReach(unit, $0) && damageFromTerrain(unit, at: $0) <= 0 }
        if let t = target { moveUnit(unitId, toward: t) }
        return !(self.unit(unitId)?.hasMovement ?? false)
    }
    func tryEnterOwnClosestCity(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId) else { return false }
        guard let city = cities(of: unit.civId).enumerated().sorted(by: { ($0.element.coord.distance(to: unit.coord), $0.offset) < ($1.element.coord.distance(to: unit.coord), $1.offset) }).map({ $0.element }).first(where: { canReach(unit, $0.coord) }) else { return false }
        moveUnit(unitId, toward: city.coord)
        return true
    }
    /// Unciv City.canBombard
    func canBombard(_ city: City) -> Bool { rs.constants.baseCityBombardRange > 0 && city.resistanceTurns == 0 && !city.attackedThisTurn }
    /// Unciv CityCombatant.getAttackingStrength (0.75 × city strength) × the city's attack modifiers
    func cityBombardStrength(_ city: City, opponent: Unit? = nil) -> Double { max(1, (cityStrength(city, attacking: true) * 0.75).rounded() * (1 + cityCombatPercent(city, attacking: true, opponent: opponent) / 100)) }
    private func bombardModifier(_ a: Double, _ d: Double) -> Double {
        let ratio = max(a, d) / max(1, min(a, d))
        let m = (pow((ratio + 3) / 4, 4) + 1) / 2
        return a >= d ? m : 1 / m
    }
    /// Unciv BattleDamage.calculateDamageToDefender for a bombarding city without randomness
    func expectedBombardDamage(_ city: City, at c: HexCoord) -> Double {
        // Unciv BattleDamage.calculateDamageToDefender: `damageModifier(ratio, false, randomnessFactor)` and the
        // randomnessFactor DEFAULTS to `getRandomness(defender)` - the same state-based draw the real attack
        // uses, not a flat 30. The AI's bombard choice is decided with it: measured on t_45, Adrianople sees
        // the same four targets with the same strengths in both engines (a8.00 against def 12.65/15.40/7/7),
        // and Unciv scores them 20/20/36/37 where our flat 30 scored 22/18/32/32 - a tie it broke by list
        // order, so it shelled the archer on -4,-7 instead of the one on -2,-4.
        if let enemyCity = self.city(at: c) { return 30 * bombardModifier(cityBombardStrength(city), cityDefendingStrength(enemyCity, attacker: nil)) }
        guard let target = units(at: c).first(where: { $0.isMilitary }) ?? units(at: c).first else { return 0 }
        if target.isCivilian { return Double(BattleConstants.damageToCivilianUnit) }   // Unciv BattleDamage: a civilian defender takes a flat 40, whoever is shooting
        // Unciv: the barbarian difficulty bonus applies to a bombarding city as much as to a unit
        return 30 * bombardModifier(cityBombardStrength(city, opponent: target), effectiveStrength(target, attacking: false, ranged: true, opponentIsCity: true))
    }
    /// Unciv Battle.attack with a CityCombatant attacker (see Battle.swift)
    @discardableResult
    func cityBombard(cityId: Int, target c: HexCoord) -> String {
        guard let city = self.city(cityId), canBombard(city), bombardableTiles(city).contains(c), let defender = getMapCombatantOfTile(c) else { return "" }
        let name = cName(defender)
        let dealt = attack(.city(cityId), defender)
        return cIsDefeated(defender) && !defender.isCity ? "\(name) destroyed" : "\(city.name) → \(name) (\(dealt.attackerDealt))"
    }
    /// Unciv UnitAutomation.tryBombardEnemy: civilians skipped, the target taking the most damage from the city
    func tryBombardEnemy(_ city: City) -> Bool {
        guard canBombard(city) else { return false }
        var best: (coord: HexCoord, expected: Int)? = nil
        for c in bombardableTiles(city) {
            // Unciv `getMapCombatantOfTile(it)!!` then `filterNot { it is MapUnitCombatant && it.isCivilian() }` -
            // the tile's combatant (city, else military unit - aircraft aside -, else civilian), not its first unit
            guard let combatant = getMapCombatantOfTile(c) else { continue }
            if combatant.isMapUnitCombatant && cIsCivilian(combatant) { continue }
            // Unciv chooseBombardTarget ranks with `BattleDamage.calculateDamageToDefender(CityCombatant(city), it)`,
            // whose randomnessFactor DEFAULTS to `getRandomness(defender)` - the same state-based draw the real
            // shot uses, not a flat 30. expectedBombardDamage is 30-based and cityBombard multiplies the draw
            // back in, so the factor belongs here, in the ranking, and only here.
            //
            // calculateDamageToDefender ends in `roundToInt()`, so `maxByOrNull` compares WHOLE numbers and the
            // near-ties among them are real ties, broken by the order of getBombardableTiles. Comparing the
            // fractions instead resolves ties that Unciv leaves standing: measured on `t_45` turn 45,
            // Adrianople scored the Warrior on -4,-4 at 35.715 and the Archer on -4,-7 at 35.960 - both 36 to
            // Unciv, which shelled the first of them and killed the Warrior; we shelled the Archer, the Warrior
            // lived, and Japan besieged the city with one more unit than Unciv's for the rest of the game.
            let expected = calculateDamageToDefender(.city(city.id), combatant)   // BattleDamage.calculateDamageToDefender(CityCombatant(city), it)
            if best == nil || expected > best!.expected { best = (c, expected) }
        }
        if ProcessInfo.processInfo.environment["BOMBX"] != nil {
            let lst = bombardableTiles(city).map { c -> String in
                let p = uncivPosition(c)
                let u = units(at: c).first(where: { $0.isMilitary }) ?? units(at: c).first
                let ds = u.map { effectiveStrength($0, attacking: false, ranged: true, opponentIsCity: true) } ?? 0
                let asx = cityBombardStrength(city, opponent: u)
                let r = combatRandomness(at: c)
                let exp = expectedBombardDamage(city, at: c) * (0.8 + 0.4 * r)
                return "\(p.x),\(p.y)=\(u?.name ?? (self.city(at: c)?.name ?? "-"))d\(Int(expectedBombardDamage(city, at: c)))x\(String(format: "%.4f", r))=\(String(format: "%.3f", exp))[a\(String(format: "%.2f", asx))/def\(String(format: "%.2f", ds))hp\(u?.health ?? 0)]"
            }
            let cp = uncivPosition(city.coord), ch = uncivPosition(best?.coord ?? city.coord)
            print("BOMBX t=\(turn) \(city.name)@\(cp.x),\(cp.y) chosen=\(best == nil ? "-" : "\(ch.x),\(ch.y)") all=[\(lst.joined(separator: " "))]")
        }
        guard let chosen = best else { return false }
        return !cityBombard(cityId: city.id, target: chosen.coord).isEmpty
    }
    private func tryTakeBackCapturedCity(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId) else { return false }
        // Unciv `unit.civ.getKnownCivs().flatMap { it.cities }`: known civs in diplomacy order, each its own cities -
        // the stable distance sort below keeps that order for ties, where ours kept the global city list's.
        var captured = knownCivs(unit.civId).flatMap { cities(of: $0.id) }.filter { areAtWar(unit.civId, $0.civId) && $0.originalOwner == unit.civId && $0.resistanceTurns > 0 && $0.health < cityMaxHealth($0) }
        if unit.def.isRanged { captured = captured.filter { $0.health != 1 } }
        let sorted = captured.map { $0.coord }.enumerated().sorted { ($0.element.distance(to: unit.coord), $0.offset) < ($1.element.distance(to: unit.coord), $1.offset) }.map { $0.element }   // Unciv sortedBy, stable
        for c in sorted { if let p = path(for: unit, to: c), !p.isEmpty { return headTowardsEnemyCity(unitId, c, path: p) } }
        return false
    }
    /// Kotlin's sortedBy is stable and Swift's sorted(by:) is not, so two cities the same distance away were
    /// picked between by the sort's internals rather than by the order the civ founded them, as Unciv does.
    private func tryGarrisoningLandUnit(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId), !unit.def.isWater else { return false }
        // Unciv `centerTile.militaryUnit == null`: an aircraft based in the city is not its garrison
        let without = cities(of: unit.civId).filter { c in militaryUnitOn(c.coord) == nil && canMoveTo(unit, c.coord) }
        var toTry: [City]
        if !isAtWarAtAll(unit.civId) {
            if map[unit.coord]?.isCityCenter == true { return true }
            toTry = without
        } else {
            // Unciv `unit.getTile().getCity()!!` - whichever city the unit stands in, not only one of ours
            if let here = city(at: unit.coord), isCityThatNeedsDefendingInWartime(here) { return true }
            let needing = without.filter { isCityThatNeedsDefendingInWartime($0) }
            toTry = needing.isEmpty ? without : needing
        }
        guard let target = toTry.enumerated().sorted(by: { ($0.element.coord.distance(to: unit.coord), $0.offset) < ($1.element.coord.distance(to: unit.coord), $1.offset) }).map({ $0.element }).first(where: { canReach(unit, $0.coord) }) else { return false }
        moveUnit(unitId, toward: target.coord)
        return true
    }
    private func isCityThatNeedsDefendingInWartime(_ city: City) -> Bool {
        if city.health < cityMaxHealth(city) { return true }
        for enemy in civsAtWarWith(city.civId) { for ec in cities(of: enemy.id) where ec.coord.distance(to: city.coord) <= 5 { return true } }
        return false
    }
    /// Unciv UnitAutomation.automatedExplore (the player's "Explore" order)
    func automatedExplore(_ unitId: Int) {
        if tryGoToRuin(unitId) && !(unit(unitId)?.hasMovement ?? false) { return }
        if let u = unit(unitId), u.health < 80, tryHealUnit(unitId) { return }
        if tryExplore(unitId) { return }
        if let u = unit(unitId) { notify(u.civId, "\(u.shortDisplayName) finished exploring.", category: .Units, icons: [u.name, "OtherIcons/Sleep"], actions: [.unit(u.coord, u.id)]); setOrder(unitId: unitId, .none) }
    }
}
