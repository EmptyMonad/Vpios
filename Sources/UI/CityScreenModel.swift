// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// What the city screen shows that is worked out from the game - Unciv CityScreen.update's tables: the CityStatsTable,
/// the CityConstructionsTable with its construction buttons, the ConstructionInfoTable of a selected construction, the
/// CityTileGroups and the CityScreenTileTable - for one city as the game stands. Every value is computed the first time
/// the screen asks for it and then kept, so the screen reads each one from here instead of recomputing it wherever the
/// SwiftUI body happens to run. What only the screen knows (the selection, whose turn it is) stays with the screen.
@MainActor
final class CityScreenModel {
    /// What the model was worked out from: the game (a new turn or a load brings a new GameState), its revision
    /// (GameController.refresh moves it after every action), the city and the civ the map is drawn for
    struct Key: Equatable { let state: ObjectIdentifier; let revision: Int; let cityId: Int; let viewerId: Int }
    /// The model a CityScreen keeps between its body evaluations - a class, so keeping a new one is no state change
    final class Box { var key: Key? = nil; var model: CityScreenModel? = nil }
    /// `--city-screen-selftest --dump` reads every construction row as rendered: the lists are built all at once then
    static var eagerLists = false

    let s: GameState
    let city: City
    /// Unciv CityTileGroup.update(cityView.viewingCiv()) and CityScreenTileTable: the civ the world map is drawn for
    let viewerId: Int

    init(state: GameState, city: City, viewerId: Int) {
        self.s = state
        self.city = city
        self.viewerId = viewerId
    }
    /// The model the city screen last read from (`--city-screen-selftest --dump` prints what the screen shows)
    static weak var shown: CityScreenModel?

    // MARK: - CityStatsTable

    lazy var stats: GameState.CityStats = s.computeStats(for: city)
    /// MiniStatsTable's happiness: this city's part of the civ's happiness breakdown
    lazy var happiness: Double = s.happinessBreakdown(city.civId, onlyCity: city.id).total
    lazy var freePopulation: Int = s.freePopulation(city)
    /// Unciv CityScreen.nextTileToOwn: the tile the borders take next (also whether the city can still expand)
    lazy var nextTileToOwn: HexCoord? = s.chooseNewTileToOwn(city)
    /// Unciv CityStatsTable turnsToExpansionString: "[n] turns to expansion" / "Stopped expansion" + " (stored🎵/needed🎵)".
    lazy var expansionText: String = {
        let choosable = nextTileToOwn != nil
        let need = s.expansionCost(for: city)
        var text: String
        if stats.total.culture > 0 && choosable { text = L("[\(max(1, Int(((need - city.expansionCulture) / stats.total.culture).rounded(.up))))] turns to expansion") }
        else { text = L("Stopped expansion") }
        if choosable { text += " (\(Int(city.expansionCulture))🎵/\(Int(need))🎵)" }
        return text
    }()
    /// Unciv CityStatsTable turnsToPopString: "[n] turns to lose population" / "Food converts to production" / "[n] turns to
    /// new population" / "Stopped population growth", then " (stored🍎/needed🍎)".
    lazy var populationText: String = {
        let turns: String
        if stats.foodForNextTurn < 0 { turns = L("[\(Int((city.foodStored / -stats.foodForNextTurn).rounded(.down)) + 1)] turns to lose population") }
        else if case .unit(let n) = city.currentProduction ?? .building(""), s.rs.units[n]?.excessFoodToProduction == true { turns = L("Food converts to production") }
        else if let g = stats.growthTurns { turns = L("[\(g)] turns to new population") }
        else { turns = L("Stopped population growth") }
        return turns + " (\(Int(city.foodStored))🍎/\(Int(s.growthCost(city)))🍎)"
    }()
    /// addText resourceTable: the city-level resources this city has (supply and stockpile)
    lazy var cityWideResources: [(String, Int)] = {
        let generated = s.resourcesGeneratedByCity(city, includeCivUniques: true)
        var counts: [String: Int] = [:]
        for (r, n) in generated { counts[r, default: 0] += n }
        for (r, n) in city.resourceStockpiles { counts[r, default: 0] += n }
        return counts.filter { s.rs.resources[$0.key]?.isCityWide == true && !(s.rs.resources[$0.key]?.uniques.contains { $0.hasPrefix("Not shown on world screen") } ?? false) }
            .sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }()
    struct GreatPersonRow { let name: String; let perTurn: Double; let now: Double; let needed: Double }
    /// Unciv CityStatsTable.addGreatPersonPointInfo: this city's points per turn, against the civ's progress
    lazy var greatPeople: [GreatPersonRow] = {
        guard city.civId == s.playerId else { return [] }
        let perTurn = s.greatPersonPointsPerTurn(city.civId, onlyCity: city.id)
        return perTurn.keys.sorted().map { gp in
            GreatPersonRow(name: gp, perTurn: perTurn[gp] ?? 0, now: s.player.greatPersonPoints[gp] ?? 0, needed: max(1, s.greatPersonThreshold(s.player, for: gp)))
        }
    }()
    /// Unciv CityScreen.updateAnnexAndRazeCityButton: "May not annex cities", and City.canBeDestroyed
    lazy var canAnnex: Bool = !s.civUniques(s.playerId).contains { $0.pattern == "May not annex cities" }
    lazy var canRaze: Bool = s.canRaze(city)

    // MARK: - CityConstructionsTable

    lazy var queue: [Production] = s.combinedQueue(city)
    /// Unciv getConstructionButtonDTOs: every ruleset unit, then every building, that shouldBeDisplayed - with its most
    /// important rejection when it is listed despite one - minus a RequiresBuildingInThisCity entry whose required
    /// building is listed too.
    lazy var entries: [(Production, ConstructionRejection?)] = {
        let umT = UIMeasure.start(); defer { UIMeasure.stop("constructionEntries", umT) }
        guard let owner = s.civ(city.civId) else { return [] }
        var out: [(Production, ConstructionRejection?)] = []
        // ruleset.units.values: every unit, great people too - another nation's or a replaced unit is left out by its
        // UniqueToOtherNation / ReplacedByOurUnique rejection, a great person with no purchase unique by its Unbuildable
        // one; a Great Prophet the era's "May buy" unique lets the city buy stays listed (canBePurchasedWithAnyStat)
        for u in s.rs.unitOrder.compactMap({ s.rs.units[$0] }) {
            let p = Production.unit(u.name)
            if s.unitRejections(u, city: city).isEmpty { out.append((p, nil)) }
            else if let r = s.displayedRejection(p, city: city) { out.append((p, r)) }
        }
        for b in s.rs.availableBuildingDefs(for: owner.nation) {
            let p = Production.building(b.name)
            if queue.contains(p) { continue }   // Building.shouldBeDisplayed: not while constructed or enqueued
            if s.buildingRejections(b, city: city).isEmpty { out.append((p, nil)) }
            else if let r = s.displayedRejection(p, city: city) { out.append((p, r)) }
        }
        let listedBuildings = Set(out.compactMap { e -> String? in if case .building(let n) = e.0 { return n }; return nil })
        return out.filter { p, r in
            guard case .building(let n) = p, r?.type == "RequiresBuildingInThisCity", let req = s.rs.buildings[n]?.requiredBuilding else { return true }
            return !(listedBuildings.contains(req) || s.rs.buildings.values.contains { listedBuildings.contains($0.name) && $0.replaces == req })
        }
    }()
    struct Section { let title: String; let entries: [(Production, ConstructionRejection?)] }
    /// Unciv updateAvailableConstructions: Units, Buildings, Wonders, National Wonders - the non-empty ones - then Other and
    /// Disabled; a construction disabled in this city (cityView.getDisabledConstructions(): the city's own set) goes under Disabled
    lazy var sections: [Section] = {
        let disabled = city.disabledConstructions
        let enabledEntries = entries.filter { !disabled.contains($0.0.name) }
        let units = enabledEntries.filter { $0.0.isUnit }
        let buildings = enabledEntries.filter { e in if case .building(let n) = e.0 { return s.rs.buildings[n].map { !$0.isWonder && !$0.isNationalWonder } ?? false }; return false }
        let wonders = enabledEntries.filter { e in if case .building(let n) = e.0 { return s.rs.buildings[n]?.isWonder == true }; return false }
        let national = enabledEntries.filter { e in if case .building(let n) = e.0 { return s.rs.buildings[n]?.isNationalWonder == true }; return false }
        return [Section(title: "Units", entries: units), Section(title: "Buildings", entries: buildings), Section(title: "Wonders", entries: wonders), Section(title: "National Wonders", entries: national)]
            .filter { !$0.entries.isEmpty }
    }()
    lazy var blacklisted: [(Production, ConstructionRejection?)] = entries.filter { city.disabledConstructions.contains($0.0.name) }
    /// PerpetualConstruction.perpetualConstructionsMap that shouldBeDisplayed (isBuildable), in the map's order: the stat
    /// conversions the civ may use, then Idle's "Produce [Nothing]", which is always buildable; one disabled in this
    /// city goes under "Disabled" like any other construction
    lazy var perpetuals: [String] = {
        let conversions = s.productionConversions(for: city.civId, city: city)
        return City.perpetualConstructions.filter { $0 == City.idleConstruction || conversions.contains($0) }
    }()
    lazy var otherPerpetuals: [String] = perpetuals.filter { !city.disabledConstructions.contains($0) }
    lazy var disabledPerpetuals: [String] = perpetuals.filter { city.disabledConstructions.contains($0) }

    /// Unciv CityView.getResourceRequirementsPerTurn(construction): the resources a construction consumes per turn
    func consumes(_ p: Production) -> [(String, Int)] {
        if let c = consumesMemo[p] { return c }
        let reqs: [String: Int]
        switch p {
        case .unit(let n):
            guard let d = s.rs.units[n] else { consumesMemo[p] = []; return [] }
            reqs = s.resourceRequirementsPerTurn(requiredResource: d.requiredResource, uniques: d.uniqueObjects, ctx: GameState.UniqueContext(civId: city.civId))
        case .building(let n):
            guard let d = s.rs.buildings[n] else { consumesMemo[p] = []; return [] }
            reqs = s.resourceRequirementsPerTurn(requiredResource: d.requiredResource, uniques: d.uniqueObjects, ctx: GameState.UniqueContext(civId: city.civId, city: city))
        }
        let out = reqs.filter { $0.value != 0 }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        consumesMemo[p] = out
        return out
    }
    private var consumesMemo: [Production: [(String, Int)]] = [:]

    /// Unciv getTurnsToConstructionString: an Unbuildable construction (conditionals holding) shows no cost line
    func isUnbuildable(_ p: Production) -> Bool {
        if let u = unbuildableMemo[p] { return u }
        let u = s.isUnbuildable(p, city: city)
        unbuildableMemo[p] = u
        return u
    }
    private var unbuildableMemo: [Production: Bool] = [:]

    /// Unciv getConstructionButton's text under the name: getTurnsToConstructionString (a unit not yet queued counts no
    /// stored progress), the resources it needs, and the rejection reason
    func rowDetail(_ p: Production, rejection: ConstructionRejection?) -> String {
        if let d = rowDetailMemo[p] { return d }
        let umT = UIMeasure.start(); defer { UIMeasure.stop("rowDetail", umT) }
        let useStored = { if case .unit = p { return !queue.contains(p) }; return true }()
        var lines = s.turnsToConstructionLines(p, in: city, useStored: useStored)
        let needs = consumes(p).map { "\($0.1) \(L($0.0))" }
        if !needs.isEmpty { lines.append(needs.joined(separator: ", ")) }
        if let r = rejection, r.type != "ConsumesResources", !r.message.isEmpty { lines.append(L(r.message)) }
        let d = lines.joined(separator: "\n")
        rowDetailMemo[p] = d
        return d
    }
    private var rowDetailMemo: [Production: String] = [:]

    /// Unciv CityConstructions.canAddToQueue (the + button, while the city can be changed)
    func canAddToQueue(_ p: Production) -> Bool {
        if let c = canAddMemo[p] { return c }
        let c = s.canAddToQueue(p, in: city)
        canAddMemo[p] = c
        return c
    }
    private var canAddMemo: [Production: Bool] = [:]

    struct QueueEntryInfo { let costLine: String?; let consumes: [String] }
    /// Unciv getQueueEntry: "[progress/]cost⚙ turns⏳" (only the first copy counts the stored progress) unless Unbuildable,
    /// and "Consumes [n] [resource]" per resource
    func queueEntry(_ index: Int) -> QueueEntryInfo {
        if let q = queueMemo[index] { return q }
        let p = queue[index]
        let first = queue.firstIndex(of: p) == index
        let done = first ? s.workDone(p, in: city) : 0
        let cost: String? = isUnbuildable(p) ? nil
            : (done == 0 ? "" : "\(done)/") + "\(s.productionCost(p, for: city.civId))⚙️ \(s.turnsToConstruction(p, in: city, useStored: first) ?? 0)⏳"
        let lines = consumes(p).map { res, amount in L("Consumes [\(amount)] [\(res)]") + (s.rs.resources[res]?.isStockpiled == true ? " /⏳" : "") }
        let q = QueueEntryInfo(costLine: cost, consumes: lines)
        queueMemo[index] = q
        return q
    }
    private var queueMemo: [Int: QueueEntryInfo] = [:]

    static let statGlyph = ["Gold": "💰", "Food": "🍎", "Science": "🔬", "Culture": "🎵", "Faith": "🕊"]
    /// getProductionTooltip: the production over the conversion rate per turn; nothing for Idle
    func perpetualDetail(_ name: String) -> String {
        guard name != City.idleConstruction else { return "" }   // Idle.getProductionTooltip = ""
        let rate = max(1, Int((1 / max(0.0001, s.statConversionRate(city.civId, name))).rounded()))
        return "\(Int((stats.total.production / Double(rate)).rounded()))\(Self.statGlyph[name] ?? "")/⏳"
    }
    /// The perpetual's + button: cannotAddConstructionToQueue does not hold (room left, not queued already)
    func canAddPerpetual(_ name: String) -> Bool { s.canAddPerpetualToQueue(name, in: city) && city.convertProductionTo != name }

    // MARK: - ConstructionInfoTable + BuyButtonFactory

    struct BuyButton { let stat: String; let cost: Int?; let allowed: Bool }
    struct SelectedInfo {
        let costLine: String?
        let description: String
        /// ConstructionInfoTable.showSellButton: the text, and whether it is enabled apart from canCityBeChanged
        let sell: (text: String, enabled: Bool)?
        let buy: [BuyButton]
        let blockedByUnit: Bool
        /// the unit's "Use default promotions" checkbox: nil when the city has none saved for it
        let useDefaultPromotions: Bool?
    }
    /// Unciv ConstructionInfoTable: the portrait, "[progress/]cost⚙ turns⏳", the description; the Sell button for a
    /// building the city has, otherwise BuyButtonFactory's buttons - one per currency it canBePurchasedWithStat
    /// ("Buy cost glyph", `cost` nil for the lone disabled "Buy" when nothing can buy it), `allowed` being
    /// isConstructionPurchaseAllowed with the reserve (godMode aside); the "Move unit out of city first" tooltip
    func selected(_ p: Production) -> SelectedInfo {
        if let i = selectedMemo[p] { return i }
        let done = s.workDone(p, in: city)
        let cost: String? = isUnbuildable(p) ? nil : (done == 0 ? "" : "\(done)/") + "\(s.productionCost(p, for: city.civId))⚙️ \(s.turnsToConstruction(p, in: city) ?? 0)⏳"
        let description: String = {
            switch p {
            case .unit(let n): return s.rs.units[n].map { ObjectDescriptions.cityUnit($0, city: city, s: s) } ?? ""
            case .building(let n): return s.rs.buildings[n].map { ObjectDescriptions.cityBuilding($0, city: city, s: s) } ?? ""
            }
        }()
        var sell: (text: String, enabled: Bool)? = nil
        var buy: [BuyButton] = []
        if case .building(let b) = p, city.buildings.contains(b) {
            if let def = s.rs.buildings[b], s.isSellable(def) {
                sell = (L("Sell") + " \(s.goldForSellingBuilding(b)) 💰", !s.hasFreeBuilding(city, b) && !city.isPuppet && (!city.hasSoldBuildingThisTurn || s.settings.godMode))
            }
        } else {
            for st in ["Gold"] + GameState.statsUsableToBuy {
                if !s.canBePurchasedWithStat(p, city: city, stat: st) {
                    if st == "Gold" && !s.canBePurchasedWithAnyStat(p, city: city) { buy.append(BuyButton(stat: st, cost: nil, allowed: false)) }
                } else if let c = s.getStatBuyCost(p, city: city, stat: st) {
                    buy.append(BuyButton(stat: st, cost: c, allowed: s.isConstructionPurchaseAllowed(p, city: city, stat: st) && (s.settings.godMode || reserve(st) >= Double(c))))
                }
            }
        }
        let blocked = s.canBePurchasedWithAnyStat(p, city: city) && s.isConstructionPurchaseBlockedByUnit(p, city: city)
        var promotions: Bool? = nil
        if case .unit(let un) = p, city.defaultPromotions[un] != nil { promotions = city.useDefaultPromotions.contains(un) }
        let info = SelectedInfo(costLine: cost, description: description, sell: sell, buy: buy, blockedByUnit: blocked, useDefaultPromotions: promotions)
        selectedMemo[p] = info
        return info
    }
    private var selectedMemo: [Production: SelectedInfo] = [:]
    /// Unciv City.getStatReserve (gold is the treasury)
    func reserve(_ stat: String) -> Double { stat == "Gold" ? s.player.gold : s.statPurchaseReserve(stat, in: city) }

    // MARK: - CityTileGroups (Unciv CityScreen.addTiles / updateTileGroups, CityTileGroup.update)

    /// The icon Unciv's CityTileGroup.update puts on a tile (TileIcons/CityCenter, Blockaded, Locked, Worked, NotWorked)
    enum TileMark { case none, center, blockaded, locked, worked, notWorked }
    struct MapTile {
        let coord: HexCoord
        /// this city's own tile (tile picking)
        let owned: Bool
        let worked: Bool
        /// owningCity()?.isSameCivAs(cityView)
        let sameCiv: Bool
        let dimmed: Bool
        let yields: Stats
        let mark: TileMark
        let yieldsDimmed: Bool
        /// TileLayerTerrain's art, with the viewer's viewable resource and shown improvement; the terrain colour without art
        let layers: [String]
        let fallbackColor: Color
        /// the TileIcons/Buy price and whether the owner has the gold for it
        let purchaseCost: Int?
        let ownerCanBuy: Bool
    }
    /// Unciv CityScreen.isSpying: `isEspionageEnabled() && !isOwnedByViewer() && !viewingCiv.isSpectator()`
    lazy var isSpying: Bool = s.espionageEnabled && city.civId != viewerId && !(s.civ(viewerId)?.isSpectator ?? false)
    lazy var purchasable: Set<HexCoord> = Set(s.purchasableTiles(city))
    /// Unciv CityScreen.addTiles: every explored tile within max(getExpandRange(), getWorkRange()) of the centre - the
    /// rings the borders can still reach and another city of ours ("Move to city") too; the work range stays the
    /// work range for everything else. Each drawn and dimmed as CityTileGroup.update says, its yields computed for the
    /// viewer (gameView.civView: the world map's civ, our own unless a spectator), not the owner.
    lazy var mapTiles: [MapTile] = {
        let umT = UIMeasure.start(); defer { UIMeasure.stop("mapTiles", umT) }
        let range = max(s.rs.constants.cityExpandRange, s.rs.constants.cityWorkRange)
        let tiles = s.map.tilesWithin(city.coord, radius: range).filter { s.player.explored.contains($0) || $0 == city.coord }.compactMap { s.map[$0] }
        // Unciv TileLayerTerrain: `getViewableResource(if (isForceVisible) null else viewingCiv)` (TileView.isForceVisible)
        let forceVisible = UserSettings.debugVisibleMap || (s.civ(viewerId).map { s.isMapRevealed($0) } ?? false)
        return tiles.map { t in
            let owned = t.ownerCivId == city.civId && city.tiles.contains(t.coord)
            let worked = city.workedTiles.contains(t.coord) || t.coord == city.coord
            // Unciv CityTileGroup.update, in its order: a tile not of our civ is dimmed (0.6), one out of the work range
            // or worked by another city fully; then the city centre, no yield, blockaded, locked, worked, a yield
            // without a worker, and otherwise NotWorked. A tile of a sibling city is judged like one of ours.
            let sameCiv = t.ownerCivId == city.civId
            let inRange = t.coord.distance(to: city.coord) <= s.rs.constants.cityWorkRange   // cityView.isInRange
            let workedByOther = t.workingCityId != nil && t.workingCityId != city.id
            let dimmed = !sameCiv || !inRange || workedByOther
            let tileYields = s.tileStats(t, civId: viewerId, city: city)   // getTileStats(viewingCiv, cityView)
            let mark: TileMark = {
                if dimmed { return .none }
                if t.isCityCenter { return .center }
                if tileYields.isEmpty { return .none }
                if s.isBlockaded(t.coord, for: city.civId) { return .blockaded }
                if city.workedTiles.contains(t.coord) && city.lockedTiles.contains(t.coord) { return .locked }
                if city.workedTiles.contains(t.coord) { return .worked }
                if s.tileProvidesYield(t) { return .none }
                return .notWorked
            }()
            // dimYields: undimmed on the centre, a locked or a worked tile and one giving its yield unworked
            let yieldsDimmed = dimmed || mark == .blockaded || mark == .notWorked
            // Unciv CityTileGroup: the tile's own art layers (terrain, features, resource, improvement, city), dimmed as
            // CityTileGroup.update says - TileLayerTerrain's getViewableResource(viewingCiv) and getShownImprovement(),
            // so a spy's view shows only what we can see and the fog's last seen improvement
            var shown = t
            if !forceVisible && !s.canSeeResource(t.resource, civId: viewerId) { shown.resource = nil }
            if !t.isCityCenter { shown.improvement = s.shownImprovement(t.coord, for: viewerId) }
            let era = t.cityId.flatMap { s.city($0) }.flatMap { s.civ($0.civId)?.eraName }
            let layers = Art.shared.layers(for: shown, cityEra: era)
            var color = Color.gray
            if let td = s.rs.terrains[t.naturalWonder ?? t.baseTerrain] { color = Color(red: Double(td.rgb[0]) / 255, green: Double(td.rgb[1]) / 255, blue: Double(td.rgb[2]) / 255) }
            // Unciv CityTileGroup: satin alinabilir karoda TileIcons/Buy ikonu ve fiyat etiketi; parasi yetmezse fiyat kirmizi -
            // `cityView.owningCivView.hasStatToBuy(Stat.Gold, price)`: the city owner's gold (godMode, a zero price always)
            var cost: Int? = nil, canBuy = false
            if purchasable.contains(t.coord) {
                let c = s.tilePurchaseCost(city, tile: t.coord)
                cost = c
                canBuy = s.settings.godMode || c == 0 || (s.civ(city.civId)?.gold ?? 0) >= Double(c)
            }
            return MapTile(coord: t.coord, owned: owned, worked: worked, sameCiv: sameCiv, dimmed: dimmed, yields: tileYields, mark: mark,
                           yieldsDimmed: yieldsDimmed, layers: layers, fallbackColor: color, purchaseCost: cost, ownerCanBuy: canBuy)
        }
    }()

    // MARK: - CityScreenTileTable

    struct TileTableInfo {
        let title: String
        let yields: String
        let ownedBy: String?
        let workedBy: String?
        /// Lock / Unlock for a tile this city works
        let lockTitle: String?
        /// "Buy for [n] gold" and whether it is enabled apart from whose turn it is
        let buy: (cost: Int, enabled: Bool)?
        /// TileBuyMenu: one entry per ring up to the work range with buyable tiles, skipping a ring that adds none over the
        /// previous one; no menu at all when fewer than two tiles could be bought
        let rings: [(ring: Int, count: Int, cost: Int)]
        /// "Move to city": another city of ours on this tile
        let moveToCity: Int?
    }
    /// Unciv CityScreenTileTable: `getTileStats(cityView.viewingCiv(), cityView)` and TileDescription.toMarkup(tileView,
    /// viewingCiv) - the viewer's techs and golden age for the viewed city, the resource it can see, getShownImprovement()
    func tileTable(_ coord: HexCoord) -> TileTableInfo? {
        if let i = tileTableMemo[coord] { return i }
        guard let t = s.map[coord] else { return nil }
        let y = s.tileStats(t, civId: viewerId, city: city)
        let owningCity = t.ownerCivId.flatMap { _ in s.cities.first { $0.tiles.contains(coord) } }
        let workingCity = t.workingCityId.flatMap { s.city($0) }
        let title = "\(L(t.naturalWonder ?? t.baseTerrain))\(t.features.isEmpty ? "" : ", " + t.features.map { L($0) }.joined(separator: ", "))\(t.resource.flatMap { s.canSeeResource($0, civId: viewerId) ? " · " + L($0) + (t.resourceAmount > 0 ? " (\(t.resourceAmount))" : "") : nil } ?? "")\(s.shownImprovement(coord, for: viewerId).map { " · " + L($0) } ?? "")"
        var buy: (cost: Int, enabled: Bool)? = nil
        var rings: [(ring: Int, count: Int, cost: Int)] = []
        if purchasable.contains(coord) {
            let cost = s.tilePurchaseCost(city, tile: coord)
            buy = (cost, city.civId == s.playerId && (s.settings.godMode || s.player.gold >= Double(cost)))
            let maxRing = s.rs.constants.cityWorkRange
            let counts = (0...maxRing).map { s.purchasableTiles(city, inRing: $0).count }
            if counts.reduce(0, +) >= 2 {
                rings = (0...maxRing).compactMap { r in
                    (counts[r] == 0 || (r > 0 && counts[r] == counts[r - 1])) ? nil : (ring: r, count: counts[r], cost: s.ringPurchaseCost(city, ring: r))
                }
            }
        }
        let other = s.city(at: coord).flatMap { oc in oc.id != city.id && oc.civId == city.civId ? oc.id : nil }
        let info = TileTableInfo(title: title, yields: y.short,
                                 ownedBy: owningCity.flatMap { $0.id != city.id ? L("Owned by [\($0.name)]") : nil },
                                 workedBy: workingCity.flatMap { $0.id != city.id ? L("Worked by [\($0.name)]") : nil },
                                 lockTitle: city.workedTiles.contains(coord) ? (city.lockedTiles.contains(coord) ? L("Unlock") : L("Lock")) : nil,
                                 buy: buy, rings: rings, moveToCity: other)
        tileTableMemo[coord] = info
        return info
    }
    private var tileTableMemo: [HexCoord: TileTableInfo] = [:]

    // MARK: - self-test dump

    /// Everything above as text, one value per line (`--city-screen-selftest --dump`): the stats table, the constructions
    /// with their texts, the info table of every one of them, every tile of the city map and its tile table
    func dumpLines() -> [String] {
        var out: [String] = []
        let st = stats
        func n(_ d: Double) -> String { "\(Int(d.rounded()))" }
        out.append("mini prod=\(n(st.total.production)) food=\(n(st.foodSurplus)) gold=\(n(st.total.gold - Double(st.maintenance))) sci=\(n(st.total.science)) cul=\(n(st.total.culture)) happy=\(n(happiness))" + (s.religionEnabled ? " faith=\(n(st.total.faith))" : ""))
        out.append("unassigned \(max(0, freePopulation))/\(city.population)")
        out.append("expansion \(expansionText)")
        out.append("population \(populationText)")
        out.append("resources " + cityWideResources.map { "\($0.0)=\($0.1)" }.joined(separator: ","))
        for g in greatPeople { out.append("greatPerson \(L(g.name)) (+\(Int(g.perTurn.rounded()))) \(Int(g.now))/\(Int(g.needed))") }
        out.append("annex canAnnex=\(canAnnex) canRaze=\(canRaze)")
        for i in queue.indices {
            let q = queueEntry(i)
            out.append("queue \(i) \(L(queue[i].name)) | \(q.costLine ?? "-") | " + q.consumes.joined(separator: " ; "))
        }
        for sec in sections {
            for (p, r) in sec.entries { out.append("row [\(sec.title)] \(L(p.name)) red=\(r != nil) add=\(canAddToQueue(p)) | " + rowDetail(p, rejection: r).replacingOccurrences(of: "\n", with: "⏎")) }
        }
        for name in otherPerpetuals { out.append("perpetual [Other] \(L("Produce [\(name)]")) | \(perpetualDetail(name)) add=\(canAddPerpetual(name))") }
        for (p, r) in blacklisted { out.append("row [Disabled] \(L(p.name)) red=\(r != nil) add=\(canAddToQueue(p)) | " + rowDetail(p, rejection: r).replacingOccurrences(of: "\n", with: "⏎")) }
        for name in disabledPerpetuals { out.append("perpetual [Disabled] \(L("Produce [\(name)]")) | \(perpetualDetail(name)) add=\(canAddPerpetual(name))") }
        var shown: [Production] = queue
        for e in entries where !shown.contains(e.0) { shown.append(e.0) }
        for b in city.buildings.sorted() where !shown.contains(.building(b)) { shown.append(.building(b)) }
        for p in shown {
            let i = selected(p)
            out.append("selected \(L(p.name)) | \(i.costLine ?? "-") | sell=\(i.sell.map { "\($0.text)/\($0.enabled)" } ?? "-") | buy=" + i.buy.map { "\($0.stat):\($0.cost.map(String.init) ?? "-"):\($0.allowed)" }.joined(separator: ",")
                       + " | blocked=\(i.blockedByUnit) promotions=\(i.useDefaultPromotions.map { "\($0)" } ?? "-")")
            out.append("selected \(L(p.name)) description " + i.description.replacingOccurrences(of: "\n", with: "⏎"))
        }
        out.append("map spying=\(isSpying) next=\(nextTileToOwn.map { "\($0.q),\($0.r)" } ?? "-")")
        for t in mapTiles {
            out.append("tile \(t.coord.q),\(t.coord.r) owned=\(t.owned) worked=\(t.worked) sameCiv=\(t.sameCiv) dimmed=\(t.dimmed) mark=\(t.mark) yields=\(t.yields.short) yieldsDimmed=\(t.yieldsDimmed) cost=\(t.purchaseCost.map(String.init) ?? "-")/\(t.ownerCanBuy) art=" + t.layers.joined(separator: ","))
            if let tt = tileTable(t.coord) {
                out.append("tileTable \(t.coord.q),\(t.coord.r) \(tt.title) | \(tt.yields) | \(tt.ownedBy ?? "-") | \(tt.workedBy ?? "-") | lock=\(tt.lockTitle ?? "-") | buy=\(tt.buy.map { "\($0.cost)/\($0.enabled)" } ?? "-") | rings=" + tt.rings.map { "\($0.ring):\($0.count):\($0.cost)" }.joined(separator: ",") + " | move=\(tt.moveToCity.map(String.init) ?? "-")")
            }
        }
        return out
    }
}
