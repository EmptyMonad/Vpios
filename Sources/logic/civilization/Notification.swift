// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Unciv Notification.NotificationCategory.
enum NotificationCategory: String, Codable, CaseIterable {
    case General, Trade, Diplomacy, Production, Units, War, Religion, Espionage, Cities
}

/// Per-notification data beyond the text (Unciv Notification: category, icons, actions).
struct NotificationMeta: Codable, Equatable {
    var category: NotificationCategory = .General
    var icons: [String] = []
    var actions: [NotificationAction] = []
}

struct NotificationItem: Identifiable {
    let index: Int
    let text: String
    let meta: NotificationMeta
    var id: Int { index }
}

/// Unciv NotificationsLog: a turn's worth of notifications, kept so the player can look back.
struct NotificationLogEntry: Codable, Equatable {
    var turn: Int
    var texts: [String] = []
    var meta: [NotificationMeta] = []
    var items: [NotificationItem] {
        texts.enumerated().map { i, t in NotificationItem(index: i, text: t, meta: i < meta.count ? meta[i] : NotificationMeta()) }
    }
}


/// Unciv GameInfo.notifyOfCloseEnemyUnits / addBombardNotification / notifyExploredResources and the city-state barbarian call.
extension GameState {
    /// Unciv Civilization.viewableTiles in its own walk. CivInfoTransientCache.setNewViewableTiles builds
    /// `HashSet<Tile>(ourTilesAndNeighboringTiles)` - our cities' tiles each followed by its neighbours, made distinct
    /// in that order (Sequence.toSet is a LinkedHashSet) - and adds every unit's viewableTiles that we do not own,
    /// the tiles of the cities of our allied city-states (or of our ally), and the tiles our spies see. A HashSet<Tile>
    /// under the reference's identity hash of 1 walks as JavaHash1Set does over that insertion sequence.
    /// Filtered to what we see now; anything our own visibility holds that the walk did not reach goes last.
    func viewableTilesUncivOrder(_ civId: Int) -> [HexCoord] {
        let seen = visibleTiles(for: civId)
        var ours: [HexCoord] = [], inOurs: Set<HexCoord> = []
        for c in cities(of: civId) {   // Unciv updateOurTiles: `cities.flatMap { getTiles() }.flatMap { sequenceOf(it) + it.neighbors }.toSet()`
            for t in uncivTileWalk(c) { for n in [t] + tilesAtDistanceUncivOrder(t, 1) where inOurs.insert(n).inserted { ours.append(n) } }
        }
        var inserts = ours
        // `getCivUnits().flatMap { unit.viewableTiles.filter { it.getOwner() != civInfo } }`
        for u in units where u.civId == civId { inserts += unitViewableTilesUncivOrder(u).filter { map[$0]?.ownerCivId != civId } }
        // `for (otherCiv in getKnownCivs()) if (otherCiv.allyCiv == civInfo || otherCiv == civInfo.allyCiv) addAll(otherCiv.cities.flatMap { getTiles() })`
        let myAlly = ally(of: civId)
        for other in knownCivs(civId) where ally(of: other.id) == civId || other.id == myAlly {
            for c in cities(of: other.id) { inserts += uncivTileWalk(c) }
        }
        // EspionageManager.getTilesVisibleViaSpies: a set-up spy's city centre, `getTilesInDistance(1)`
        for spy in civ(civId)?.spies ?? [] where spy.alive && GameState.spySetUpActions.contains(spy.action) {
            if let cid = spy.cityId, let c = city(cid) { inserts += [c.coord] + tilesAtDistanceUncivOrder(c.coord, 1) }
        }
        // java.util.HashSet(Collection) on the reference's JDK 19: `HashMap.newHashMap(max(c.size(), 12))` = ceil(n / 0.75)
        let walk = JavaHash1Set.iterationOrder(inserts, initialCapacity: JavaHash1Set.jdk19CollectionCapacity(ours.count)).filter { seen.contains($0) }
        let walked = Set(walk)
        return walk + seen.filter { !walked.contains($0) }.sorted { ($0.q, $0.r) < ($1.q, $1.r) }
    }

    /// Enemy military units inside or next to our borders, and cities that could bombard them (run when a human's turn begins).
    /// Unciv reads `tile.militaryUnit` - the land or naval military unit; aircraft sit in `airUnits` and never count -
    /// and walks `viewableTiles` in its HashSet order, which is the order of the notifications and of their positions.
    /// Ours took the first military unit of any kind (a Fighter parked in a border city was "spotted") and sorted by (q, r).
    func notifyOfCloseEnemyUnits(_ civId: Int) {
        guard let me = civ(civId) else { return }
        var inside: [HexCoord] = [], near: [HexCoord] = []
        for c in viewableTilesUncivOrder(civId) {
            guard let u = militaryUnitOn(c), u.civId != civId, me.isAtWar(with: u.civId) else { continue }
            // Unciv notifyOfCloseEnemyUnits: Kotlin'de `&&` `||`'dan sıkı bağladığı için görünmezlik testi
            // yalnızca "near our territory" dalına uygulanır — kendi toprağımızdaki birim her hâlükârda duyurulur.
            if map[c]?.ownerCivId == civId { inside.append(c); continue }
            if u.def.isInvisible && !visibleUnits(for: civId).contains(where: { $0.id == u.id }) { continue }
            if map.neighbors(of: c).contains(where: { map[$0]?.ownerCivId == civId }) { near.append(c) }
        }
        func report(_ tiles: [HexCoord], _ inOrNear: String) {
            if tiles.count < 3 {
                for t in tiles { if let u = militaryUnitOn(t) { notify(civId, "An enemy [\(u.name)] was spotted \(inOrNear) our territory", category: .War, icons: ["War", u.name], actions: [.location(t)], coord: t) } }
            } else {
                notify(civId, "[\(tiles.count)] enemy units were spotted \(inOrNear) our territory", category: .War, icons: ["War"], actions: tiles.map { .location($0) }, coord: tiles.first)
            }
        }
        report(inside, "in"); report(near, "near")
        let close = inside + near
        let bombarders = cities(of: civId).filter { c in c.health > 0 && c.resistanceTurns == 0 && !c.attackedThisTurn && close.contains { $0.distance(to: c.coord) <= rs.constants.baseCityBombardRange } }
        if bombarders.count < 3 {
            // Unciv `MapUnitAction(city.location)` - no unit id: the tile's city (or unit) is selected, ready to bombard
            for c in bombarders { notify(civId, "Your city [\(c.name)] can bombard the enemy!", category: .War, icons: ["City", "Crosshair"], actions: [.unit(c.coord, -1)], coord: c.coord) }
        } else if !bombarders.isEmpty {
            notify(civId, "[\(bombarders.count)] of your cities can bombard the enemy!", category: .War, icons: ["City", "Crosshair"], actions: bombarders.map { .unit($0.coord, -1) }, coord: bombarders.first?.coord)
        }
    }

    /// Unciv GameInfo.notifyExploredResources: "[resource] revealed near [city]" / "[n] sources of [resource] revealed,
    /// e.g. near [city]" built by getExploredResourcesNotification. Unciv adds it with `civInfo.notifications.add`,
    /// not addNotification: no AI gate of its own (addTechnology asks for a Human first) and no EvLog NOTIF line, which
    /// the reference prints only inside addNotification. Ours built its own list - foreign and city-state land left
    /// out, our allied city-states' cities never counted, each tile measured to its own closest city - and went
    /// through notify(), so the count, the city named, the positions' order and whether it appeared at all differed.
    @discardableResult
    func notifyExploredResources(_ civId: Int, resource: String, maxDistance: Int = Int.max, filter: (Tile) -> Bool = { _ in true }) -> Bool {
        guard let item = exploredResourcesNotification(civId, resource: resource, maxDistance: maxDistance, filter: filter),
              let i = civIndex(civId) else { return false }
        // keep the three parallel arrays aligned even if an older save left them uneven (as notify() does)
        while civs[i].notificationCoords.count < civs[i].notifications.count { civs[i].notificationCoords.append(nil) }
        while civs[i].notificationMeta.count < civs[i].notifications.count { civs[i].notificationMeta.append(NotificationMeta()) }
        civs[i].notifications.append(item.text)
        civs[i].notificationCoords.append(item.meta.actions.compactMap { if case .location(let c) = $0 { return c }; return nil }.first)
        civs[i].notificationMeta.append(item.meta)
        return true
    }

    /// Unciv GameInfo.getExploredResourcesNotification: the explored sources of a resource the civ can see (a
    /// city-state-only resource at its city-states' capitals), crossed with our cities and our allied city-states'
    /// cities, kept where `distance <= maxDistance && filter(tile)`, ours first, then by distance (a stable sort), one
    /// pair per tile; the positions re-sorted by distance to the chosen city.
    func exploredResourcesNotification(_ civId: Int, resource: String, maxDistance: Int = Int.max, filter: (Tile) -> Bool = { _ in true }) -> NotificationItem? {
        guard let me = civ(civId), let def = rs.resources[resource], canSeeResource(resource, civId: civId) else { return nil }
        // Unciv `civ.cities + civ.getKnownCivs().filter { isCityState && allyCiv == civ }.flatMap { cities }` - known civs in diplomacy (HashMap) order
        let relevant = cities(of: civId) + knownCivs(civId).filter { $0.isCityState && ally(of: $0.id) == civId }.flatMap { cities(of: $0.id) }
        let sources: [Tile] = def.uniques.contains("Can only be created by Mercantile City-States")
            ? cityStates.filter { $0.isAlive && $0.cityStateResource == resource }.compactMap { capital(of: $0.id).flatMap { map[$0.coord] } }
            : map.tilesInUncivOrder().filter { $0.resource == resource }   // Unciv tileMap.values
        var pairs: [(city: City, tile: Tile, distance: Int, n: Int)] = []
        for t in sources where me.explored.contains(t.coord) {
            for c in relevant {
                let d = c.coord.distance(to: t.coord)
                if d <= maxDistance && filter(t) { pairs.append((c, t, d, pairs.count)) }
            }
        }
        // Kotlin sortedWith is stable: equal keys keep the cross join's order
        pairs.sort { a, b in
            let ka = a.city.civId != civId ? 1 : 0, kb = b.city.civId != civId ? 1 : 0
            return (ka, a.distance, a.n) < (kb, b.distance, b.n)
        }
        var seen: Set<HexCoord> = []
        pairs = pairs.filter { seen.insert($0.tile.coord).inserted }
        guard let chosen = pairs.first?.city else { return nil }
        let positions = pairs.enumerated().map { ($0.element.tile.coord, $0.offset) }
            .sorted { ($0.0.distance(to: chosen.coord), $0.1) < ($1.0.distance(to: chosen.coord), $1.1) }.map(\.0)
        let text = positions.count == 1 ? "[\(resource)] revealed near [\(chosen.name)]" : "[\(positions.count)] sources of [\(resource)] revealed, e.g. near [\(chosen.name)]"
        return NotificationItem(index: -1, text: text, meta: NotificationMeta(category: .General, icons: ["ResourceIcons/\(resource)"], actions: positions.map { .location($0) }))
    }

    /// Unciv QuestManager.tryBarbarianInvasion: a city-state with two or more threatening barbarian units calls its known neighbours for help.
    func tryBarbarianInvasion(cityState cs: Civilization) {
        guard let ci = civIndex(cs.id), (civs[ci].civFlags["TurnsTillCallForBarbHelp"] ?? 0) <= 0, let cap = capital(of: cs.id) else { return }
        guard let barb = barbarianCivId else { return }
        let owned = Set(cities(of: cs.id).flatMap { $0.tiles })
        let threatening = units.filter { u in u.civId == barb && map.tilesWithin(u.coord, radius: 1).contains { owned.contains($0) } }.count   // Unciv threatensCiv: any barbarian unit
        guard threatening >= 2 else { return }
        for other in majorCivs where other.isAlive && cs.metCivs.contains(other.id) && !cs.isAtWar(with: other.id) && proximity(other.id, cs.id) <= .far {
            notify(other.id, "[\(cs.nation)] is being invaded by Barbarians! Destroy Barbarians near their territory to earn Influence.", category: .Diplomacy, icons: [cs.nation, "War"], actions: [.location(cap.coord)], coord: cap.coord)
        }
        civs[ci].civFlags["TurnsTillCallForBarbHelp"] = 30
    }

    /// Unciv DiplomacyManager.getTurnsToRelationshipChange for a major's standing with a city-state.
    func turnsToRelationshipChange(_ major: Int, _ cityState: Int) -> Int {
        let decay = cityStateInfluenceDegrade(major, cityState)   // Unciv getTurnsToRelationshipChange
        guard decay > 0 else { return 0 }
        let inf = influence(of: major, with: cityState)
        if isAlly(major, of: cityState) { return Int(((inf - 60) / decay).rounded(.up)) + 1 }
        if isFriend(major, of: cityState) { return Int(((inf - GameState.friendThreshold) / decay).rounded(.up)) + 1 }
        return 0
    }

    /// Unciv Civilization.revealMapWhenDefeated: a defeated single-player human sees the whole map.
    func revealMapWhenDefeated(_ civId: Int) {
        guard !settings.isOnline, let i = civIndex(civId), civs[i].isPlayer else { return }
        civs[i].explored = Set(map.tiles.indices.filter { !map.missing.contains($0) }.map { map.tiles[$0].coord })   // gameInfo.tileMap.values
        checkExploredRegionForWholeMap(i)   // each Tile.setExplored also widens a human player's exploredRegion
    }

    /// Unciv CityStats.isConnectedToCapital(RoadStatus.Railroad): the city is in the civ's STORED connection map with a
    /// railroad medium (Railroad, or a harbour reached from a railroad). The map is written only by
    /// updateCitiesConnectedToCapital (turn start, a building added or removed, the load): a railroad finished
    /// mid-turn is not a connection until then (fresh turn 179: Orleans' +25% Railroad production came a turn
    /// early here), and a city that has changed hands is in neither owner's map until the next update.
    func railroadConnectedCityIds(_ civId: Int) -> Set<Int> {
        let own = Set(cities(of: civId).map { $0.id })
        if let stored = civ(civId)?.citiesConnectedByRailroad { return Set(stored).intersection(own) }
        return Set(findCapitalConnections(civId).filter { $0.mediums.contains { $0.isRailroad } }.map { $0.cityId }).intersection(own)
    }
    /// Unciv CityStats.getRoadTypeOfConnectionToCapital: the best roadType among the city's mediums in the STORED
    /// connection map (RoadStatus ordinal: None 0, Road 1, Railroad 2). The capital holds Start (None) and gains a
    /// medium only when a BFS run from another reached city comes back to it - a railroad or a harbour route from a
    /// railroad-reached harbour city makes the capital itself "Railroad".
    func roadTypeOfConnectionToCapital(_ city: City) -> Int {
        if railroadConnectedCityIds(city.civId).contains(city.id) { return 2 }
        if let stored = civ(city.civId)?.citiesConnectedByRoad { return stored.contains(city.id) ? 1 : 0 }
        return findCapitalConnections(city.civId).first { $0.cityId == city.id }.map { $0.mediums.map { $0.roadLevel }.max() ?? 0 } ?? 0
    }
}
