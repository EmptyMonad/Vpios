// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct City: Codable, Identifiable {
    let id: Int
    /// Unciv `City.id`: the UUID string a save carries, and what `GameContext.hashCode` hashes for the city.
    /// Our own integer `id` is an index into our arrays and means nothing to Unciv, so every state-based roll
    /// that involves a city has to hash this instead if the two engines are to draw the same number.
    @Lenient var uncivId: String = ""
    /// Unciv `@Transient City.hasJustBeenConquered`: set by Battle.conquerCity, cleared by moveToCiv - military units
    /// may enter the city (and captured civilians stay) before it changes hands, and no second attack targets it. A
    /// transient City.clone does not copy: every load and every Next Turn clone starts it false, so a conquest a human
    /// has not decided yet (its CityConquered alert dropped unanswered under AutoPlay) can be attacked again next turn.
    @Transient var hasJustBeenConquered: Bool = false
    /// Unciv `@Transient City.currentGPPBonus` ("temporary variable saved for rankSpecialist()"): set only by
    /// autoAssignPopulation when it has citizens to place, and read by Automation.rankSpecialist - so the
    /// unassignment that runs without it ranks specialists with whatever the last assignment left (0 after a load).
    @Transient var currentGPPBonus: Int = 0
    var civId: Int
    var name: String
    let coord: HexCoord
    var population: Int = 1
    var foodStored: Double = 0
    var productionStored: Double = 0
    @Lenient var inProgressConstructions: [String: Int] = [:]   // Unciv CityConstructions.inProgressConstructions (other than the current one)
    @Lenient var productionOverflow: Int = 0                      // Unciv CityConstructions.productionOverflow
    var currentProduction: Production? = nil {
        didSet {
            // Unciv keeps progress per construction name: park the old item's work, resume the new one's
            guard oldValue != currentProduction else { return }
            if ProcessInfo.processInfo.environment["SETPROD_CITY"] == name { print("SETPRODE \(name) \(oldValue?.name ?? "-") -> \(currentProduction?.name ?? "-") " + Thread.callStackSymbols.dropFirst(1).prefix(8).map { String($0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).first ?? "") }.joined(separator: " < ")) }
            if let old = oldValue { let w = Int(productionStored); if w > 0 { inProgressConstructions[old.name] = w } else { inProgressConstructions.removeValue(forKey: old.name) } }
            productionStored = Double(currentProduction.map { inProgressConstructions.removeValue(forKey: $0.name) ?? 0 } ?? 0)
            workDoneOn = productionStored > 0 ? (currentProduction?.name ?? "") : ""
            if EvLog.on { EvLog.productionSet(self) }
        }
    }
    @Lenient var convertProductionTo: String = ""   // the perpetual queue entry (Unciv PerpetualConstruction): "Gold" / "Science" / ... or Idle's "Nothing"; "" is none
    @Lenient var demandedResource: String = ""      // luxury the citizens ask for (We Love The King Day)
    @Lenient var wltkdTurns: Int = 0                // turns of celebration left
    @Lenient var resourceDemandCooldown: Int = -1   // Unciv CityFlags.ResourceDemand countdown (-1 = not set)
    @Lenient var isOccupied: Bool = false           // conquered and annexed; unhappy until a courthouse
    @Lenient var productionQueue: [Production] = [] // built after the current item, in order
    /// Unciv CityConstructions.freeBuildingsProvidedFromThisCity (GainFreeBuildings), filed under this city's own id.
    /// The civ's own grants (FreeStatBuildings / FreeSpecificBuildings) live on the civ (freeBuildingsOfCities), and
    /// GameState.freeBuildingNames joins the two through the CURRENT owner, as CivConstructions.getFreeBuildingNames does.
    @Lenient var freeBuildingsProvidedFromThisCity: [String] = []
    @Lenient var reservedImprovementTile: HexCoord? = nil   // Unciv: the tile a CreatesOneImprovement construction has claimed
    @Lenient var reservedImprovement: String = ""
    @Lenient var originalOwner: Int = -1            // founder, for liberation
    @Lenient var previousOwner: Int = -1            // Unciv City.previousOwner: who held it before the current owner
    @Lenient var currentConstructionIsUserSet: Bool = false   // Unciv CityConstructions.currentConstructionIsUserSet
    @Lenient var isOriginalCapital: Bool = false     // Unciv City.isOriginalCapital: the founder's first city
    @Lenient var acquiredTurn: Int = 0              // turn the current owner got the city (plunder scaling)
    @Lenient var workDoneOn: String = ""            // construction that already received production (Unciv getWorkDone > 0)
    @Lenient var avoidGrowth: Bool = false          // Unciv City.avoidGrowth: food is capped at the growth threshold
    @Lenient var shouldReassignPopulation: Bool = false   // Unciv City.shouldReassignPopulation: reassign citizens at the next turn start
    @Lenient var cityFocus: String = "NoFocus"      // Unciv CityFocus name used by citizen auto-assignment
    @Lenient var hasSoldBuildingThisTurn: Bool = false
    @Lenient var attackedThisTurn: Bool = false      // Unciv City.attackedThisTurn (saved): set when the city bombards, cleared in CityTurnManager.startTurn
    @Lenient var manualSpecialists: Bool = false     // Unciv City.manualSpecialists: the player places specialists by hand
    @Lenient var disabledConstructions: Set<String> = []   // Unciv CityScreenConstructionMenu "Disable in this city"
    @Lenient var connectedToCapital: Bool = false   // Unciv CivInfoTransientCache.citiesConnectedToCapital: last known link, for the connected/disconnected notifications
    @Lenient var resourceStockpiles: [String: Int] = [:]   // Unciv City.resourceStockpiles (city-level stockpiled resources)
    @Lenient var defaultPromotions: [String: SavedUnitPromotions] = [:]   // Unciv City.unitToPromotions: the saved UnitPromotions newly trained units of that name copy
    @Lenient var useDefaultPromotions: Set<String> = []          // Unciv City.unitShouldUseSavedPromotion
    var isCelebrating: Bool { wltkdTurns > 0 }
    /// Unciv CityConstructions.builtBuildings (the names, a set) - kept in the order the buildings were added.
    var buildings: [String] = []
    /// Unciv CityConstructions.builtBuildingObjects is an ArrayList: addBuilding appends (`withItem`) even a building
    /// the city already has, removeBuilding drops ONE copy (`withoutItem`). The copies beyond `buildings` live here -
    /// in practice the Palace a resurrecting liberation adds twice (moveToCiv's moveCapitalTo, then liberateCity's
    /// capital indicator) - and every walk of getBuiltBuildings() sees them, until the game is loaded again
    /// (setTransients rebuilds the list from the names).
    @Lenient var duplicateBuildingObjects: [String] = []
    /// Unciv getBuiltBuildings(): the built building objects, duplicates included.
    var builtBuildingObjects: [String] { duplicateBuildingObjects.isEmpty ? buildings : buildings + duplicateBuildingObjects }
    var tiles: Set<HexCoord> = []
    /// The order the tiles were put into the set.
    ///
    /// Unciv's City.tiles is a Kotlin HashSet<HexCoord>, and several decisions are settled by the order it walks -
    /// which sea resource a work boat improves, which city-state tile a great merchant walks to, where a citadel
    /// goes. That walk is not the insertion order, but it is derived from it (GameState.uncivTileWalk), so the
    /// insertion order has to be kept to reproduce it. A save gives it to us directly: libGDX writes a HashSet in
    /// its walk order, so the array in the file is the order Unciv itself would walk.
    @Lenient var tilesOrder: [HexCoord] = []
    /// The table City.tiles sits in when it is larger than its size implies (0: the one the size implies) - see
    /// tilesWithoutItem. GameState.uncivTileWalk walks `tilesOrder` over it.
    @Lenient var tilesTable: Int = 0
    /// HashSet.add in place - the save reader filling the set tile by tile.
    mutating func addTile(_ c: HexCoord) { if tiles.insert(c).inserted { tilesOrder.append(c); if EvLog.on { EvLog.tileOwner(c, city: self, owned: true) } } }
    /// Unciv `tiles = tiles.withItem(c)` (CityExpansionManager.takeOwnership): `HashSet(this)` - on the reference's
    /// JDK 19 a table sized for the set as it is, filled in the set's walk (`walk`, GameState.uncivTileWalk) - and
    /// the tile added to it, the table growing if it must: the table the new size implies, the old walk re-bucketed.
    mutating func tilesWithItem(_ c: HexCoord, walk: [HexCoord]) {
        tilesOrder = walk
        tilesTable = 0
        if tiles.insert(c).inserted { tilesOrder.append(c); if EvLog.on { EvLog.tileOwner(c, city: self, owned: true) } }
    }
    /// Unciv `tiles = tiles.withoutItem(c)` (CityExpansionManager.relinquishOwnership): the copy is sized for the set
    /// BEFORE the tile leaves and keeps that table - 12 tiles left of 13 stay in 32 slots where a set grown to 12
    /// has 16, 24 of 25 in 64 - so every later walk buckets them as that table does, until the next copy.
    mutating func tilesWithoutItem(_ c: HexCoord, walk: [HexCoord]) {
        tilesTable = javaHashTableLength(tiles.count)
        tilesOrder = walk.filter { $0 != c }
        if tiles.remove(c) != nil { if EvLog.on { EvLog.tileOwner(c, city: self, owned: false) } }
    }
    /// Replace the whole set, keeping the order of the tiles that survive.
    mutating func replaceTiles(_ s: Set<HexCoord>) {
        let kept = tilesOrder.filter { s.contains($0) }
        tiles = s
        tilesOrder = kept + s.subtracting(kept).sorted { ($0.q, $0.r) < ($1.q, $1.r) }
        tilesTable = 0
    }
    /// Unciv City.workedTiles, a HashSet<HexCoord>: the tiles in the order they went into the set now held - each
    /// City.workTile / stopWorkingTile makes a new one (`withItem` / `withoutItem`) - walked by GameState.workedTilesWalk.
    var workedTiles: [HexCoord] = []
    /// The table City.workedTiles sits in when it is larger than its size implies (0: the one the size implies).
    @Lenient var workedTilesTable: Int = 0
    /// Unciv City.workTile: `workedTiles = workedTiles.withItem(tile.position)` - the set copied in its walk (`walk`,
    /// GameState.workedTilesWalk) into the table its size implies, then the tile added (see tilesWithItem).
    mutating func workedTilesWithItem(_ c: HexCoord, walk: [HexCoord]) {
        workedTiles = walk
        workedTilesTable = 0
        if !workedTiles.contains(c) { workedTiles.append(c) }
    }
    /// Unciv City.stopWorkingTile: `workedTiles = workedTiles.withoutItem(tile.position)` - the copy keeps the table
    /// of the size before the removal (see tilesWithoutItem): a city starving from 13 worked tiles to 12 walks them
    /// over 32 slots when it picks the next worst tile.
    mutating func workedTilesWithoutItem(_ c: HexCoord, walk: [HexCoord]) {
        workedTilesTable = javaHashTableLength(workedTiles.count)
        workedTiles = walk.filter { $0 != c }
    }
    var health: Int = 200
    var expansionCulture: Double = 0
    var foundedTurn: Int = 0
    var resistanceTurns: Int = 0
    var wondersBeingBuilt: Set<String> = []
    var razing: Bool = false
    var isPuppet: Bool = false
    /// Citizen assignments fixed by the player. Unciv's City.lockedTiles is a HashSet<HexCoord> changed in place
    /// (lockTile / unlockTile): a tile added goes to the end, one removed leaves, and the table only grows - kept in
    /// lockedTilesOrder / lockedTilesTable for reassignPopulation's `workedTiles = lockedTiles`. The callers that
    /// make a new set (`lockedTiles = hashSetOf()`) reset lockedTilesTable themselves.
    var lockedTiles: Set<HexCoord> = [] {
        didSet {
            let now = lockedTiles
            if now.count < oldValue.count || !oldValue.isSubset(of: now) { lockedTilesOrder.removeAll { !now.contains($0) } }
            let added = lockedTiles.subtracting(oldValue)
            if !added.isEmpty { lockedTilesOrder += added.sorted { ($0.q, $0.r) < ($1.q, $1.r) } }
            lockedTilesTable = max(lockedTilesTable, javaHashTableLength(oldValue.count), javaHashTableLength(lockedTiles.count))
        }
    }
    @Lenient var lockedTilesOrder: [HexCoord] = []
    @Lenient var lockedTilesTable: Int = 0
    /// Unciv CityReligionManager.pressures is a Counter - a LinkedHashMap: a new religion goes to the END, a count
    /// that reaches 0 is removed (Counter.put). The order decides which of two equal religions wins the city
    /// (updateNumberOfFollowers walks it; getMajorityReligionName keeps the first maximum), so it is kept beside
    /// the dictionary: every write appends new keys and drops zeroed ones. Several keys added in ONE assignment get
    /// no defined order - add them one at a time, as Unciv does.
    var religionPressure: [String: Double] = [:] {
        didSet {
            let zeroed = religionPressure.filter { $0.value == 0 }.map { $0.key }
            if !zeroed.isEmpty { var p = religionPressure; for k in zeroed { p[k] = nil }; religionPressure = p }   // Counter.put(key, 0) removes
            let present = religionPressure
            var order = religionPressureOrder.filter { present[$0] != nil }
            for k in present.keys.sorted() where !order.contains(k) { order.append(k) }
            religionPressureOrder = order
        }
    }
    @Lenient var religionPressureOrder: [String] = []
    /// The pressures in Unciv's Counter order (an old save without the order falls back to the names, sorted, after it).
    var orderedPressureKeys: [String] {
        let known = religionPressureOrder.filter { religionPressure[$0] != nil }
        return known + religionPressure.keys.filter { !known.contains($0) }.sorted()
    }
    @Lenient var religionsAtSomePointAdopted: Set<String> = []   // Unciv CityReligionManager.religionsAtSomePointAdopted
    var isHolyCity: Bool = false
    var holyCityOf: String? = nil
    var inquisitorProtected: Bool = false
    /// specialist name -> citizens assigned. Unciv CityPopulationManager.specialistAllocations is a Counter - a
    /// LinkedHashMap: a kind goes to the END when it is first allocated, and leaves when its count reaches 0
    /// (Counter.put). That order decides which of two equally ranked specialists unassignExtraPopulation drops, and
    /// the order the civ's great person counter first meets great people in (GreatPersonPointsBreakdown walks
    /// getNewSpecialists()) - so it is kept beside the dictionary, as religionPressureOrder is. Several kinds added in
    /// ONE assignment get no defined order: add them one at a time.
    var specialists: [String: Int] = [:] {
        didSet {
            let present = specialists
            var order = specialistOrder.filter { (present[$0] ?? 0) != 0 }
            for k in present.keys.sorted() where present[k] != 0 && !order.contains(k) { order.append(k) }
            specialistOrder = order
        }
    }
    @Lenient var specialistOrder: [String] = []
    /// The specialists in Unciv's Counter order (an old save without the order falls back to the names, sorted, after it).
    var orderedSpecialistKeys: [String] {
        let known = specialistOrder.filter { (specialists[$0] ?? 0) != 0 }
        return known + specialists.keys.filter { (specialists[$0] ?? 0) != 0 && !known.contains($0) }.sorted()
    }
    var isCapital: Bool { builtBuildingObjects.contains(Names.palace) }   // Unciv: builtBuildingUniqueMap.hasUnique(IndicatesCapital) - the objects, a second copy included

    static let maxHealth = 200

    /// Unciv PerpetualConstruction.Idle.name: "Produce [Nothing]", the entry a queue the player emptied is left with
    static let idleConstruction = "Nothing"
    /// Unciv PerpetualConstruction.perpetualConstructionsMap, in its order: the stat conversions, then Idle
    static let perpetualConstructions = ["Science", "Gold", "Culture", "Faith", "Food", idleConstruction]
    /// Unciv CityConstructions.isQueueEmptyOrIdle: nothing queued at all, or only PerpetualConstruction.Idle
    var isQueueEmptyOrIdle: Bool { currentProduction == nil && (convertProductionTo.isEmpty || convertProductionTo == City.idleConstruction) }

    var foodToGrow: Double {
        let p = Double(population - 1)
        return (15 + 8 * p + pow(p, 1.5)).rounded(.down)
    }
}

/// Unciv City.unitToPromotions value: a UnitPromotions - the promotions, the spendable XP (which
/// CityConstructions.completeConstruction compares the new unit's against) and the promotion count.
///
/// PromotionPickerScreen.checkSaveUnitPromotion stores the saving unit's OWN object (`= unit.promotions`), so while
/// that MapUnit is part of the game being played the record follows it: XP and promotions it gains later are what
/// a unit bought this turn copies. The object stops changing once nothing plays that MapUnit any more - the next
/// turn runs on WorldScreen.nextTurn's clone (City.clone shares the map, MapUnit.clone copies the promotions), an
/// undo restores a clone, a load reads a copy, the unit is destroyed, or an upgrade replaces it with a new MapUnit
/// (copyStatisticsTo clones the promotions). `unitId` / `unitName` name that live unit; nil once frozen.
struct SavedUnitPromotions: Codable, Equatable {
    var promotions: [String] = []
    var xp: Int = 0
    var numberOfPromotions: Int = 0
    var unitId: Int? = nil
    var unitName: String? = nil
    init(promotions: [String] = [], xp: Int = 0, numberOfPromotions: Int = 0, unitId: Int? = nil, unitName: String? = nil) {
        self.promotions = promotions; self.xp = xp; self.numberOfPromotions = numberOfPromotions; self.unitId = unitId; self.unitName = unitName
    }
    private enum CodingKeys: String, CodingKey { case promotions, xp, numberOfPromotions, unitId, unitName }
    init(from decoder: Decoder) throws {
        // Saves from before the XP was kept held the promotion names alone.
        if let names = try? decoder.singleValueContainer().decode([String].self) { promotions = names; return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        promotions = try c.decodeIfPresent([String].self, forKey: .promotions) ?? []
        xp = try c.decodeIfPresent(Int.self, forKey: .xp) ?? 0
        numberOfPromotions = try c.decodeIfPresent(Int.self, forKey: .numberOfPromotions) ?? 0
        unitId = try c.decodeIfPresent(Int.self, forKey: .unitId)
        unitName = try c.decodeIfPresent(String.self, forKey: .unitName)
    }
}
