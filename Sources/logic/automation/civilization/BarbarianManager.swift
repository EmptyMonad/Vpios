// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Barbarian encampments and their raiders.
extension GameState {
    var barbarianCivId: Int? { civs.first { $0.isBarbarian }?.id }

    func createBarbarianCiv() {
        guard barbarianCivId == nil else { return }
        var civ = Civilization(id: newId(), nation: Names.barbarians, isPlayer: false)
        civ.isBarbarian = true
        civs.append(civ)
        for i in civs.indices where !civs[i].isBarbarian { civs[i].atWarWith.insert(civ.id); civs[civs.count - 1].atWarWith.insert(civs[i].id) }
    }

    func campTiles() -> [HexCoord] { map.tiles.filter { $0.hasBarbarianCamp }.map { $0.coord } }

    func placeInitialCamps(startPositions: [HexCoord]) { placeBarbarianEncampment(forTesting: true) }

    /// Units that barbarians may currently field: land military units that some civ can already build.
    func barbarianUnitPool() -> [UnitDef] {
        var known: Set<String> = []
        for c in civs where c.isAlive && !c.isBarbarian { known.formUnion(c.techs) }
        return rs.units.values.filter { u in
            u.isLand && !u.isCivilian && !u.neverBarbarian && u.uniqueTo == nil && u.cost > 0 && u.greatPersonType == nil && !u.isSpaceshipPart
                && (u.requiredTech == nil || known.contains(u.requiredTech!)) && !(u.obsoleteTech.map { known.contains($0) } ?? false)
                && !u.uniques.contains("Unbuildable")
        }.sorted { $0.cost < $1.cost }
    }

    /// Unciv BarbarianManager.updateEncampments: track destroyed camps, maybe place a new one, let each camp spawn.
    /// Unciv increments gameInfo.turns when the player cycle wraps, so every civ - the barbarians included -
    /// plays a round with the new number already set. Ours runs the barbarian turn at the end of the round,
    /// before the counter moves, which makes our `turn` the same number Unciv reads here. Subtracting one from it
    /// put every barbarian decision a full turn behind: the first wandering barbarian appeared a turn late.
    func barbarianTurn() {
        guard settings.barbarians, let barbId = barbarianCivId else { return }
        // Unciv TurnManager.automateTurn: the barbarian units act first, then the encampments update
        // Unciv TurnManager.startTurn runs for the barbarians too, and its `civInfo.cache.updateViewableTiles()`
        // (TurnManager.kt:63) comes before the units' startTurn (:77): the barbarians' stored view is written here
        // each turn - empty once their last unit is gone, as Unciv's is (a test game, t=51)
        updateExploration(for: barbId)
        // Unciv: the barbarian civilization has a turn manager of its own, so its units start their turn here
        for id in units.filter({ $0.civId == barbId }).map({ $0.id }) { unitStartTurn(id) }   // Unciv UnitTurnManager.startTurn
        notifyPromotableUnits(barbId)   // Unciv TurnManager.startTurn tells every civ, the barbarians too, which units can be promoted
        barbarianAutomate(barbId)
        // Adopt any camp that exists on the map but is not tracked yet (old saves).
        let tracked = Set(encampments.map { $0.position })
        for c in campTiles() where !tracked.contains(c) { encampments.append(Encampment(position: c)) }
        for i in encampments.indices.reversed() {
            if map[encampments[i].position]?.hasBarbarianCamp != true, !encampments[i].destroyed { encampments[i].destroyed = true; encampments[i].countdown = 15 }
            if encampments[i].destroyed && encampments[i].countdown == 0 { encampments.remove(at: i) }
        }
        placeBarbarianEncampment()
        for i in encampments.indices {
            if encampments[i].countdown > 0 { encampments[i].countdown -= 1 }
            else if !encampments[i].destroyed, spawnBarbarian(at: encampments[i].position) != nil {
                encampments[i].spawnedUnits += 1
                encampments[i].countdown = encampmentResetCountdown(spawnedUnits: encampments[i].spawnedUnits)
            }
        }
        barbarianUnitsEndTurn(barbId)
    }
    /// Unciv TurnManager.endTurn → UnitTurnManager.endTurn for the barbarian civ (never defeated): fortification and healing, then citadel and terrain damage
    private func barbarianUnitsEndTurn(_ barbId: Int) {
        // The same UnitTurnManager.endTurn every civ's units go through (UnitTurnManager.swift). Ours had a copy
        // of its own: no displacement, heal without "All healing effects doubled", aircraft spared from citadels.
        for id in units.filter({ $0.civId == barbId }).map({ $0.id }) { unitEndTurn(id) }
    }
    /// Unciv `BarbarianManager.placeBarbarianEncampent` ikinci tohum argumani olarak `encampments.hashCode()`
    /// kullanir. Unciv'de `BarbarianEncampment` `hashCode()`'u gecersiz kilmaz, yani JVM kimlik hash'i devreye girer
    /// ve deger surecten surece degisir - yani Unciv'de bu cagri kaydet/yukle arasinda aslinda deterministik DEGILDIR
    /// (`Conditionals.getStateBasedRandom` icindeki `Unique.hashCode()` hatasinin aynisi).
    /// Referans `-XX:hashCode=2` ile kosar (her kimlik hash'i 1), bu yuzden `AbstractList.hashCode()` kabugu
    /// (h = 1'den baslar, `h = 31*h + e`) eleman basina e = 1 ile hesaplanir.
    /// `encampments` bir dizidir, gezinme sirasi sabittir.
    private var encampmentsHash: Int32 {
        var h: Int32 = 1
        for _ in encampments { h = withHash(h, 1) }   // each element's identity hash: 1 under -XX:hashCode=2
        return h
    }

    /// Unciv BarbarianEncampment.resetCountdown: 8–12 turns, halved for raging barbarians, plus the difficulty delay, minus units already spawned (max 3), × speed.
    private func encampmentResetCountdown(spawnedUnits: Int) -> Int {
        // Unciv BarbarianEncampment.kt:53 -> barbar civ'in state'i, caller "BarbarianManager.resetCooldown"
        var g = stateBasedRandom("BarbarianManager.resetCooldown", civId: barbarianCivId ?? -1)
        var countdown = 8 + g.int(0...4)
        if settings.ragingBarbarians { countdown /= 2 }
        countdown += difficulty.barbarianSpawnDelay
        countdown -= min(spawnedUnits, 3)
        return Int(Float(countdown) * Float(speed.barbarianModifier))   // Unciv `(countdown * barbarianModifier).toInt()`, Float
    }
    /// Unciv BarbarianManager.campAttacked: an attacked camp spawns sooner.
    func campAttacked(at c: HexCoord) {
        // Unciv `encampments.firstOrNull { it.position == position }?.wasAttacked()`, and wasAttacked skips a destroyed camp
        if let i = encampments.firstIndex(where: { $0.position == c }), !encampments[i].destroyed { encampments[i].countdown /= 2 }
    }
    /// Unciv BarbarianManager.placeBarbarianEncampment
    func placeBarbarianEncampment(forTesting: Bool = false) {
        // Unciv BarbarianManager.kt:79: tek uretec tum yerlestirme turu icin; caller dizesi Unciv'in kendi
        // yazim hatasiyla ("Encampent") birebir, tuz ise varsayilan 31 degil `encampments.hashCode()`.
        var g = stateBasedRandom("BarbarianManager.placeBarbarianEncampent", civId: barbarianCivId ?? -1, seed: encampmentsHash)
        if !forTesting && uncivTurns > 1 && g.nextBoolean() { return }   // Unciv rng.nextBoolean(): one draw, not nextDouble
        var viewable: Set<HexCoord> = []
        for c in civs where !c.isBarbarian && !c.isSpectator { viewable.formUnion(visibleTiles(for: c.id)) }   // Unciv counts defeated civs too
        // Unciv `tileMap.values.filter { ... }`: the tiles in the save's tileList order - `viableTiles.random(rng)`
        // picks by index, so the order is the answer.
        let fogTiles = map.tilesInUncivOrder().filter { $0.isLand && !viewable.contains($0.coord) }
        let fogTilesPerCamp = Int(pow(Double(map.realTileCount), 0.4))
        var campsToAdd = fogTiles.count / max(1, fogTilesPerCamp) - encampments.filter { !$0.destroyed }.count
        if uncivTurns == 1 { campsToAdd = max(campsToAdd / 3, 1) } else if campsToAdd > 0 { campsToAdd = 1 }
        if campsToAdd <= 0 { return }
        var tooCloseToCapitals: Set<HexCoord> = []
        for c in majorCivs { if let cap = capital(of: c.id) { tooCloseToCapitals.formUnion(map.tilesWithin(cap.coord, radius: 4)) } }
        var tooCloseToCamps: Set<HexCoord> = []
        for e in encampments { tooCloseToCamps.formUnion(map.tilesWithin(e.position, radius: e.destroyed ? 4 : 7)) }
        var viable = fogTiles.filter { t in
            !t.isImpassable && t.resource == nil && !t.features.contains(where: { rs.terrains[$0]?.uniqueObjects.contains { $0.pattern == "Only [] improvements may be built on this tile" } ?? false })
                && map.neighbors(of: t.coord).contains { map[$0]?.isLand == true } && !tooCloseToCapitals.contains(t.coord) && !tooCloseToCamps.contains(t.coord)
        }.map { $0.coord }
        var added = 0
        var biasCoast = g.int(0...5) == 0
        while added < campsToAdd, !viable.isEmpty {
            var tile: HexCoord? = nil
            if biasCoast { tile = g.pick(viable.filter { c in map.isAdjacentToCoast(c) }) }   // Unciv `viableTiles.filter { it.isAdjacentToCoast() }`
            if tile == nil { tile = g.pick(viable) }
            guard let t = tile else { break }
            createNewCamp(at: t, rng: &g)   // Unciv: createNewCamp(tile, rng) - ayni akistan devam
            // Unciv notifyCivsOfBarbarianEncampment: `for (civ in gameInfo.civilizations)`, a defeated civ that still holds
            // the unique included
            for c in civs where c.explored.contains(t) && civUniques(c.id).contains(where: { $0.pattern == "Notified of new Barbarian encampments" }) {
                notify(c.id, "A new barbarian encampment has spawned!", category: .War, icons: ["War"], coord: t)   // Unciv: tile.position, NotificationIcon.War
                if let ci = civIndex(c.id), let imp = map[t]?.improvement { civs[ci].lastSeenImprovement[t] = imp }   // Unciv setLastSeenImprovement
            }
            added += 1
            if added < campsToAdd { let far = Set(map.tilesWithin(t, radius: 7)); viable.removeAll { far.contains($0) }; biasCoast = g.int(0...5) == 0 }
        }
    }
    /// Unciv BarbarianManager.createNewCamp: a random camp-equivalent improvement; features stay
    /// Unciv BarbarianManager.kt:165 varsayilan argumani:
    /// `rng: Random = tile.stateThisTile.stateBasedRandom("createNewCamp")` - karo baglamindan tohumlanir.
    func createNewCamp(at c: HexCoord) {
        guard let t = map[c] else { return }
        var g = stateBasedRandom("createNewCamp", tile: t)
        createNewCamp(at: c, rng: &g)
    }
    /// Unciv placeBarbarianEncampment uretecini `createNewCamp(tile, rng)` ile devrettigi icin
    /// ayni akistan devam eden asiri yukleme.
    func createNewCamp(at c: HexCoord, rng g: inout SeededRandom) {
        let candidates = rs.improvementOrder.filter { $0 == Names.barbarianCamp || rs.improvements[$0]?.uniques.contains("Marks a barbarian camp") == true }
        map[c]?.improvement = g.pick(candidates) ?? Names.barbarianCamp
        encampments.append(Encampment(position: c))
    }
    /// Unciv BarbarianManager.spawnBarbarian: a defender for an empty camp, otherwise a unit near the camp (naval when the
    /// randomly chosen free neighbour is water). Units for another allegiance skip the barbarian limits.
    @discardableResult
    func spawnBarbarian(at c: HexCoord, allegiance: Int? = nil) -> Unit? {
        guard let barbId = barbarianCivId else { return nil }
        let owner = allegiance ?? barbId
        if owner == barbId {
                if !units(at: c).contains(where: { $0.isMilitary }) { return spawnBarbarianUnit(at: c, naval: false, owner: owner) }
            if uncivTurns < 10 { return nil }
            let nearby = map.tilesWithin(c, radius: 4).flatMap { units(at: $0) }.filter { $0.isMilitary && $0.civId == barbId }.count
            if nearby > 2 { return nil }
        }
        let canSpawnNaval = uncivTurns > 30   // Unciv gameInfo.turns; also reached from a major civ's turn (camp recruit)
        let valid = map.neighbors(of: c).filter { n in
            guard let t = map[n] else { return false }
            return !t.isImpassable && !t.isCityCenter && units(at: n).isEmpty && (!t.isWater || canSpawnNaval) && !(terrainHasFreshWater(t) && t.isWater)
        }
        // Unciv BarbarianManager.kt:214: allegiance baska bir civ olsa da tohum her zaman barbar civ'in state'inden
        var g = stateBasedRandom("BarbarianManager.spawnBarbarian", civId: barbId)
        guard let pick = g.pick(valid) else { return nil }
        return spawnBarbarianUnit(at: c, naval: map[pick]?.isWater == true, owner: owner)
    }
    /// Unciv BarbarianManager.spawnUnit: placed at or near the camp position
    private func spawnBarbarianUnit(at c: HexCoord, naval: Bool, owner: Int) -> Unit? {
        updateBarbarianTech()
        guard let def = chooseBarbarianUnit(naval: naval) else { return nil }
        return spawnUnit(def.name, civId: owner, at: c)
    }
    /// Unciv BarbarianManager.updateBarbarianTech: the techs every living civilization has researched
    private func updateBarbarianTech() {
        guard let barbId = barbarianCivId, let bi = civIndex(barbId) else { return }
        var known = Set(rs.techs.keys)
        for c in civs where !c.isBarbarian && c.isAlive { known.formIntersection(c.techs) }
        // `techsResearched = allResearchedTechs.toHashSet()`: the transient researchedTechnologies is left alone
        let transient = civs[bi].techUniqueOrder
        civs[bi].techs = known
        civs[bi].techUniqueOrder = transient
    }
    /// Unciv BarbarianManager.chooseBarbarianUnit: buildable military units (barbarians need no resources), weighted by force evaluation
    private func chooseBarbarianUnit(naval: Bool) -> UnitDef? {
        guard let barbId = barbarianCivId else { return nil }
        let list = rs.units.values.sorted(by: { (rs.unitOrderIndex[$0.name] ?? .max) < (rs.unitOrderIndex[$1.name] ?? .max) }).filter { u in   // Unciv: ruleset JSON sirasi; randomWeighted listeyi sirayla tarar
            // Unciv filters on isBuildable(barbarianCiv), which lets a civ build its OWN unique unit. Requiring
            // uniqueTo == nil here threw out the Brute - the barbarians' only unit - so the list came back empty
            // and no barbarian was ever spawned from a camp that already had its defender.
            !u.isCivilian && !u.cannotAttack && !u.neverBarbarian && (naval ? u.isWater : u.isLand) && unitRejections(u, civId: barbId, city: nil).isEmpty
        }
        guard !list.isEmpty else { return nil }
        // Unciv BarbarianManager.kt:258: GameContext(gameInfo = gameInfo) - civ/sehir/birim/karo bos baglam
        var g = stateBasedRandom("BarbarianManager.chooseBarbarianUnit", UniqueContext(civId: -1))
        // Unciv `unitList.randomWeighted(unitList.map { it.getForceEvaluation().toFloat() }, rng)`: Float weights,
        // a Float running sum of w/total against one nextDouble
        return uncivRandomWeighted(list, &g) { Float($0.forceEvaluation) }
    }

    private func visibleToAnyCiv(_ c: HexCoord) -> Bool {
        civs.contains { civ in !civ.isBarbarian && civ.isAlive && units(of: civ.id).contains { $0.coord.distance(to: c) <= 3 } }
    }

}
