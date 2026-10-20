// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv AlertType / PopupAlert: events shown to the player as popups at the start of their turn.
enum AlertType: String, Codable {
    case Defeated, WonderBuilt, TechResearched, WarDeclaration, FirstContact, CityConquered, CityTraded, BorderConflict, TilesStolen
    case DemandToStopSettlingCitiesNear, CitySettledNearOtherCivDespiteOurPromise
    case DemandToStopSpreadingReligion, ReligionSpreadDespiteOurPromise
    case DemandToStopSpyingOnUs, SpyingOnUsDespiteOurPromise
    case DemandToNotAttackUs, AttackedUsDespitePromise
    case AcceptingDemand, RejectingDemand
    case GoldenAge, DeclarationOfFriendship, StartIntro, DiplomaticMarriage
    case BulliedProtectedMinor, AttackedProtectedMinor, AttackedAllyMinor
    case RecapturedCivilian, GameHasBeenWon, Denounced
    case Event, TradeRequest
}

extension AlertType {
    /// What an alert's value names. Unciv keeps a civ by its civID (its name), a city by its UUID, a recaptured civilian by
    /// its tile ("(x,y)") and an event by its name (plus "␟unitId=N"); ours keeps our ids - the save's import and export
    /// translate one into the other, and the POPUPLOG prints the names.
    enum ValueKind { case civ, city, civPair, unitTile, event, text }
    var valueKind: ValueKind {
        switch self {
        case .CityConquered, .CityTraded, .DiplomaticMarriage: return .city
        case .BulliedProtectedMinor, .AttackedProtectedMinor, .AttackedAllyMinor: return .civPair
        case .RecapturedCivilian: return .unitTile
        case .Event: return .event
        case .TechResearched, .WonderBuilt, .GoldenAge, .GameHasBeenWon, .StartIntro, .TradeRequest: return .text
        default: return .civ
        }
    }
}

struct PopupAlert: Codable, Equatable, Identifiable {
    var id: String { "\(type.rawValue)|\(value)" }
    let type: AlertType
    let value: String
}

extension Demand {
    var demandAlert: AlertType {
        switch self { case .DoNotSettleNearUs: return .DemandToStopSettlingCitiesNear; case .DoNotSpreadReligion: return .DemandToStopSpreadingReligion; case .DontSpyOnUs: return .DemandToStopSpyingOnUs; case .DoNotAttackUs: return .DemandToNotAttackUs }
    }
    var violationAlert: AlertType {
        switch self { case .DoNotSettleNearUs: return .CitySettledNearOtherCivDespiteOurPromise; case .DoNotSpreadReligion: return .ReligionSpreadDespiteOurPromise; case .DontSpyOnUs: return .SpyingOnUsDespiteOurPromise; case .DoNotAttackUs: return .AttackedUsDespitePromise }
    }
    static func forDemandAlert(_ t: AlertType) -> Demand? {
        switch t {
        case .DemandToStopSettlingCitiesNear, .CitySettledNearOtherCivDespiteOurPromise: return .DoNotSettleNearUs
        case .DemandToStopSpreadingReligion, .ReligionSpreadDespiteOurPromise: return .DoNotSpreadReligion
        case .DemandToStopSpyingOnUs, .SpyingOnUsDespiteOurPromise: return .DontSpyOnUs
        case .DemandToNotAttackUs, .AttackedUsDespitePromise: return .DoNotAttackUs
        default: return nil
        }
    }
}

extension AlertType {
    /// The alerts Unciv values with a civilization's civID / civName (DiplomacyFunctions.meetCiv, DeclareWar, Battle,
    /// DiplomacyManager.denounce / queueOtherCivPopupIfUnique, CityStateFunctions' border conflict, the demands,
    /// DiplomacyAutomation.offerDeclarationOfFriendship, UniqueTriggerActivation's tiles stolen); ours hold its id.
    var isCivValued: Bool {
        switch self {
        case .Defeated, .WarDeclaration, .FirstContact, .BorderConflict, .TilesStolen, .AcceptingDemand, .RejectingDemand,
             .DeclarationOfFriendship, .Denounced: return true
        default: return Demand.forDemandAlert(self) != nil
        }
    }
}

extension GameState {
    /// An alert's value as Unciv writes it: a civilization by its civID (ours: its id), the bully/attacker and the
    /// city-state as `civName@civName`, a recaptured civilian by its tile's `position.toPrettyString()` "(x,y)"
    /// (BattleUnitCapture.kt:153), an event as `name␟unitId=N` (UniqueTriggerActivation.kt:129-131, ours `name|N`);
    /// a city by the City.id our export writes for it (uncivCityId). `uncivPos` gives a tile in Unciv's coordinates.
    func uncivAlertValue(_ a: PopupAlert, uncivPos: (HexCoord) -> (x: Int, y: Int)) -> String {
        if a.type.isCivValued { return Int(a.value).flatMap { civ($0)?.nation } ?? a.value }
        switch a.type {
        case .BulliedProtectedMinor, .AttackedProtectedMinor, .AttackedAllyMinor:
            let parts = a.value.split(separator: "@").map { Int($0).flatMap { civ($0)?.nation } }
            guard parts.count == 2, let x = parts[0], let y = parts[1] else { return a.value }
            return x + "@" + y
        case .CityConquered, .CityTraded, .DiplomaticMarriage:
            return Int(a.value).map { uncivCityId($0) } ?? a.value
        case .RecapturedCivilian:
            guard let u = Int(a.value).flatMap({ unit($0) }) else { return a.value }
            let p = uncivPos(u.coord); return "(\(p.x),\(p.y))"
        case .Event:
            let parts = a.value.split(separator: "|", maxSplits: 1).map(String.init)
            return parts.count > 1 ? parts[0] + "\u{241F}unitId=" + parts[1] : a.value
        default: return a.value
        }
    }
    /// The reverse of uncivAlertValue for a loaded save: names to civ ids, Unciv's City.id to ours, "(x,y)" to the
    /// civilian unit standing there (AlertPopup.addRecapturedCivilian: `tile.civilianUnit`), `unitId=N` to the unit
    /// loaded with that id. A value that names nothing is kept as it is: the popup then does not open, as Unciv's.
    func oursAlertValue(type: AlertType, value: String, civIds: [String: Int], cityIds: [String: Int], unitIds: [Int: Int], tileAt: (Int, Int) -> HexCoord) -> String {
        if type.isCivValued { return civIds[value].map { "\($0)" } ?? value }
        switch type {
        case .BulliedProtectedMinor, .AttackedProtectedMinor, .AttackedAllyMinor:
            let parts = value.split(separator: "@", omittingEmptySubsequences: false).map { civIds[String($0)] }
            guard parts.count == 2, let x = parts[0], let y = parts[1] else { return value }
            return "\(x)@\(y)"
        case .CityConquered, .CityTraded, .DiplomaticMarriage:
            return cityIds[value].map { "\($0)" } ?? value
        case .RecapturedCivilian:
            let xy = value.trimmingCharacters(in: CharacterSet(charactersIn: "()")).split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard xy.count == 2 else { return value }
            let c = tileAt(xy[0], xy[1])
            return units.first(where: { $0.coord == c && $0.isCivilian }).map { "\($0.id)" } ?? value
        case .Event:
            let parts = value.components(separatedBy: "\u{241F}")
            guard parts.count > 1 else { return value }
            for p in parts.dropFirst() where p.hasPrefix("unitId=") {
                if let uid = Int(p.dropFirst("unitId=".count)), let ours = unitIds[uid] { return parts[0] + "|\(ours)" }
            }
            return parts[0]
        default: return value
        }
    }

    /// Unciv `civ.popupAlerts.add(...)` – kept for humans only: an AI's alerts are dropped unread by its respondToPopupAlerts
    /// (`popupAlerts.clear()`), and the two it answers, demands and Declarations of Friendship, ours queues as
    /// `pendingDemands` / `pendingOffers`. A human is a human under AutoPlay too - Unciv's AutoPlay leaves the playerType
    /// alone, adds the alerts as ever, and the automated turn's respondToPopupAlerts answers and clears them - so only the
    /// headless `--autoplay` run, where the player is played as an AI, drops them. An ArrayList: no duplicate is refused
    /// (only DiplomacyManager.queueOtherCivPopupIfUnique asks first, queueAlertIfUnique here - for AcceptingDemand and
    /// RejectingDemand alone, DiplomacyManager.kt:895,903; TilesStolen's is a plain add behind its one-turn flag).
    func addAlert(_ civId: Int, _ type: AlertType, _ value: String = "") {
        guard let i = civIndex(civId), civs[i].isPlayer, !epochsAutoplay else { return }
        let alert = PopupAlert(type: type, value: value)
        civs[i].popupAlerts.append(alert)
        // POPUPLOG (EVLOG): Unciv `civ.popupAlerts.add` for a human; a TradeRequest is Unciv's tradeRequests (queueOffer prints it)
        if GameState.evlogOn && type != .TradeRequest { ev(civId, "POPUP", type.rawValue, evAlertField(alert)) }
    }

    /// The alert's value as one POPUPLOG field - the Unciv driver's `fmt`: "-" when empty, spaces as underscores.
    func evAlertField(_ a: PopupAlert) -> String { let v = evAlertValue(a); return v.isEmpty ? "-" : EvLog.name(v) }
    /// The alert's value as the POPUPLOG prints it on both sides: a civ by its name, a city by its name, a unit by its
    /// Unciv position ("x,y"), an event by its name - Unciv keeps civ names, city UUIDs and positions, we keep our ids.
    func evAlertValue(_ a: PopupAlert) -> String {
        func civName(_ s: Substring) -> String { Int(s).flatMap { civ($0)?.nation } ?? String(s) }
        switch a.type.valueKind {
        case .city: return Int(a.value).flatMap { city($0)?.name } ?? a.value
        case .civPair: return a.value.split(separator: "@", omittingEmptySubsequences: false).map(civName).joined(separator: "@")
        case .unitTile: return Int(a.value).flatMap { unit($0) }.map { let p = uncivPosition($0.coord); return "\(p.x),\(p.y)" } ?? a.value
        case .event: return String(a.value.split(separator: "|", omittingEmptySubsequences: false).first ?? "")
        case .text: return a.value
        case .civ: return civName(Substring(a.value))
        }
    }

    /// POPUPLOG: what Unciv's respondToPopupAlerts / respondToTradeRequests find waiting for a human at the start of its
    /// automated turn - its popupAlerts (with our Declarations of Friendship kept as pending offers, after them), and its
    /// tradeRequests - each in queue order, as PopupDump.kt prints Unciv's ArrayLists: the order AlertPopup opens them in and
    /// respondToPopupAlerts walks them in (a sorted print hid it and made it look different: zcraze t=108, France's queue read
    /// from the save as FirstContact:Ragusa, WarDeclaration:Ragusa, FirstContact:Yerevan, printed sorted by ours).
    func evPopupQueues(_ civId: Int) {
        guard GameState.evlogOn else { return }
        let (pops, reqs) = popupQueueFields(civId)
        ev(civId, "POPQ", pops.isEmpty ? "-" : pops.joined(separator: ","))
        ev(civId, "TREQQ", reqs.isEmpty ? "-" : reqs.joined(separator: ","))
    }
    /// The POPQ and TREQQ fields of evPopupQueues, in queue order (alertAnswers' queueOrder checks it).
    func popupQueueFields(_ civId: Int) -> (pops: [String], reqs: [String]) {
        guard let me = civ(civId) else { return ([], []) }
        var pops = me.popupAlerts.filter { $0.type != .TradeRequest }.map { "\($0.type.rawValue):\(evAlertField($0))" }
        pops += pendingOffers.filter { $0.to == civId && $0.isFriendshipRequest }.map { "DeclarationOfFriendship:\(EvLog.name(civ($0.from)?.nation ?? "civ\($0.from)"))" }
        let reqs = pendingOffers.filter { $0.to == civId && !$0.isFriendshipRequest }.map { evTradeRequestText($0) }
        return (pops, reqs)
    }
    /// Unciv TradeRequest(requestingCiv, trade.reverse()) as the receiver keeps it: its own offers (what the requester
    /// wants) first, then the requester's - as EvLog.tradeSummary joins ourOffers and theirOffers.
    func evTradeRequestText(_ o: TradeOffer) -> String {
        EvLog.name(civ(o.from)?.nation ?? "civ\(o.from)") + ":" + GameState.evJoin(evOfferNames(o.want, other: o.give, tail: o.evTailWant) + evOfferNames(o.give, other: o.want, tail: o.evTailGive))
    }
    /// Unciv AlertPopup.close: `viewingCiv.popupAlerts.remove(popupAlert)` - the one alert shown, a second one alike stays.
    func removeAlert(_ civId: Int, _ alert: PopupAlert) {
        guard let i = civIndex(civId), let k = civs[i].popupAlerts.firstIndex(of: alert) else { return }
        civs[i].popupAlerts.remove(at: k)
    }
    /// Unciv AlertPopup handlers returning shouldOpen = false: defeated civilizations, cities or units that are gone, events
    /// without a choice - for the civ whose popup it is (AlertPopup's viewingCiv; the player unless said otherwise).
    func alertShouldOpen(_ a: PopupAlert, for viewer: Int? = nil) -> Bool {
        let s = self
        let me = viewer ?? s.playerId
        switch a.type {
        case .StartIntro, .WonderBuilt, .TechResearched, .GoldenAge, .GameHasBeenWon, .Defeated: return true
        // Unciv addFirstContact asks nothing of the civ met: a civ defeated since is still introduced
        case .FirstContact: return Int(a.value).flatMap { s.civ($0) } != nil
        // Unciv addCityConquered: the city is still the loser's while the question is open (Battle only queued the alert)
        case .CityConquered: return Int(a.value).flatMap { s.city($0) } != nil
        case .CityTraded, .DiplomaticMarriage: return Int(a.value).flatMap { s.city($0) }.map { $0.civId == me } ?? false
        case .RecapturedCivilian: return Int(a.value).flatMap { s.unit($0) }.map { s.civ($0.originalCiv)?.isAlive == true } ?? false
        case .BulliedProtectedMinor, .AttackedProtectedMinor, .AttackedAllyMinor:
            let parts = a.value.split(separator: "@").compactMap { Int($0) }
            return parts.count == 2 && s.civ(parts[0])?.isAlive == true && s.civ(parts[1]) != nil
        case .TradeRequest:
            return Int(a.value).flatMap { id in s.pendingOffers.first { $0.id == id } }.map { s.tradeIsValid($0) } ?? false
        case .DeclarationOfFriendship:
            // Unciv addDeclarationOfFriendship: `otherciv.isDefeated() || otherciv.getDiplomacyManager(viewingCiv).diplomaticStatus == War` → false
            guard let c = Int(a.value).flatMap({ s.civ($0) }), c.isAlive else { return false }
            return !s.areAtWar(c.id, me)
        case .Event:
            let parts = a.value.split(separator: "|", maxSplits: 1).map(String.init)
            guard let name = parts.first, let e = s.rs.events.first(where: { $0.name == name }) else { return false }
            return !s.matchingChoices(e, civId: me, unitId: parts.count > 1 ? Int(parts[1]) : nil).isEmpty
        default: return Int(a.value).flatMap { s.civ($0) }.map { $0.isAlive } ?? false
        }
    }
    /// The player's answer to an alert: it goes, and with it every alert that would no longer open (Unciv: shouldOpen
    /// false drops the alert). The ones kept are picked before the list is written back: alertShouldOpen reads `civs`,
    /// which a `removeAll` on `civs[i].popupAlerts` holds for its write while it runs, and Swift's exclusivity check
    /// stops the app there - as it did closing a popup with a civilization's alert behind it.
    func dismissAlert(_ civId: Int, _ a: PopupAlert) {
        removeAlert(civId, a)
        guard let i = civIndex(civId) else { return }
        let kept = civs[i].popupAlerts.filter { alertShouldOpen($0, for: civId) }
        civs[i].popupAlerts = kept
    }
    /// Unciv DiplomacyManager.queueOtherCivPopupIfUnique
    func queueAlertIfUnique(_ civId: Int, _ type: AlertType, _ value: String) {
        guard let i = civIndex(civId), !civs[i].popupAlerts.contains(where: { $0.type == type && $0.value == value }) else { return }
        addAlert(civId, type, value)
    }

    /// Unciv AlertPopup.addRecapturedCivilian "Yes": give the unit back to its original owner near their closest city.
    func returnCapturedUnit(unitId: Int, by captor: Int) {
        guard let ui = unitIndex(unitId), let orig = civ(units[ui].originalCiv), orig.id != captor else { return }
        let unit = units[ui]
        destroyUnit(unitId)   // capturedUnit.destroy()
        // Attempt to place the unit near their nearest city (UnitManager.placeUnitNearTile)
        let closest = cities(of: orig.id).min(by: { $0.coord.distance(to: unit.coord) < $1.coord.distance(to: unit.coord) })
        if let closest { _ = spawnUnit(unit.name, civId: orig.id, at: closest.coord) }
        if orig.isCityState, let oi = civIndex(orig.id) { addInfluence(cityState: civs[oi].id, major: captor, 45) }
        else if orig.isMajor { setModifier(orig.id, captor, .ReturnedCapturedUnits, 20) }
        // Unciv: LocationAction on the unit's tile and on the closest city, DiplomacyAction(captor) and
        // CivilopediaAction("Tutorial/Barbarians"), NotificationCategory.Diplomacy, NotificationIcon.Trade, the unit and the captor
        let captorName = civ(captor)?.nation ?? "?"
        notify(orig.id, "Your captured [\(unit.name)] has been returned by [\(captorName)]", category: .Diplomacy, icons: ["Trade", unit.name, captorName],
               actions: [.location(unit.coord)] + (closest.map { [.location($0.coord)] } ?? []) + [.diplomacy(captorName), .civilopedia("Tutorial/Barbarians")])
    }
    /// "No": take it for ourselves - Unciv BattleUnitCapture.captureOrConvertToWorker(capturedUnit, captor), which
    /// destroys a settler and places a new worker in its stead.
    func keepCapturedUnit(unitId: Int, by captor: Int) {
        guard unitIndex(unitId) != nil else { return }
        captureOrConvertToWorker(unitId, captor)
    }

    // MARK: Unciv RankingType / statsHistory

    static let rankingTypes = ["Score", "Population", "Growth", "Production", "Gold", "Territory", "Force", "Happiness", "Technologies", "Culture"]
    /// Unciv RankingType.entries: vanilla types plus the non-vanilla "Tiles Explored" (always recorded in statsHistory).
    static let allRankingTypes = rankingTypes + ["Tiles Explored"]
    /// Unciv RankingType.filteredEntries: non-vanilla types only when "Show additional stat types" is on.
    var shownRankingTypes: [String] { settings.showAdditionalRankingTypes ? GameState.allRankingTypes : GameState.rankingTypes }

    /// Unciv Civilization.getStatForRanking
    func statForRanking(_ civ: Civilization, _ category: String) -> Int {
        if !civ.isAlive { return 0 }
        let myCities = cities(of: civ.id)
        switch category {
        case "Score": return Int(totalScore(civ))
        case "Population": return myCities.reduce(0) { $0 + $1.population }
        // Unciv `stats.statsForNextTurn.food.roundToInt()` / `.production.roundToInt()`: the STORED civ field as
        // updateStatsForNextTurn last wrote it (every statMap row summed in Float), rounded half up (-2.5 -> -2).
        // Summing the cities' caches in Double and rounding half away from zero gave another figure.
        case "Growth":
            let f = civ.statsForNextTurn?.food ?? statMapForNextTurn(civ.id).reduce(Stats()) { ($0 + $1.1).f32 }.food
            return Stats.roundToInt(f)
        case "Production":
            let p = civ.statsForNextTurn?.production ?? statMapForNextTurn(civ.id).reduce(Stats()) { ($0 + $1.1).f32 }.production
            return Stats.roundToInt(p)
        case "Gold": return Int(civ.gold)
        case "Territory": return myCities.reduce(0) { $0 + $1.tiles.count }
        case "Force": return militaryMight(civ.id)
        case "Happiness": return happiness(of: civ.id)
        // Unciv `tech.researchedTechnologies.size`: that list gains an entry on every addTechnology, a repeated
        // Future Tech included, and is rebuilt from the set (one each) by setTransients.
        case "Technologies": return researchedTechnologiesSize(civ)
        case "Culture": return civ.adoptedPolicyCount
        case "Tiles Explored": return civ.explored.count
        default: return 0
        }
    }
    /// Unciv calculateScoreBreakdown
    func scoreBreakdown(_ civ: Civilization) -> [(String, Double)] {
        // Unciv divides by mapParameters.numberOfTiles(), which is not the number of tiles on a hexagonal map. It reads
        // the configured mapSize: an odd world-wrap width stays odd, a hexagonal map counts by its radius. Only a game
        // saved before the map kept its size falls back to what the grid stands for.
        let numberOfTiles: Int = map.uncivSize?.numberOfTiles ?? settings.uncivNumberOfTiles ?? {
            if settings.mapShape == "Rectangular" { return map.realTileCount }
            let r = map.hexRadius ?? MapGenerator.equivalentRadius(tiles: map.realTileCount)
            return 1 + 3 * r * (r - 1)
        }()
        var mod = 1276.0 / Double(max(1, numberOfTiles))
        if mod > 1 { mod = (mod - 1) / 3 + 1 }
        let myCities = cities(of: civ.id)
        let wonders = myCities.reduce(0) { $0 + $1.buildings.filter { rs.buildings[$0]?.isWonder == true }.count }
        return [
            ("Cities", Double(myCities.count) * 10 * mod),
            ("Population", Double(myCities.reduce(0) { $0 + $1.population }) * Double(rs.constants.scoreFromPopulation) * mod),
            ("Tiles", Double(myCities.reduce(0) { $0 + $1.tiles.filter { map[$0]?.isLand == true }.count }) * mod),
            ("Wonders", Double(rs.constants.scoreFromWonders * wonders)),
            ("Technologies", Double(civ.techs.count) * 4.0),
            ("Future Tech", Double(civ.futureTechs) * 10.0),
        ]
    }
    func totalScore(_ civ: Civilization) -> Double { GameState.uncivScoreSum(scoreBreakdown(civ)) }
    /// Unciv calculateTotalScore = `calculateScoreBreakdown().values.sum()`: the breakdown is a `hashMapOf<String, Double>()`,
    /// summed in its bucket order, not in the order the rows were put in. The two differ in the last bit (a state comparison, a
    /// test game turn 13: France 70.14022140221402 there, 70.14022140221404 in list order), and the Time victory's
    /// `maxByOrNull { calculateTotalScore() }` compares these Doubles exactly.
    static func uncivScoreSum(_ rows: [(String, Double)]) -> Double {
        var byKey: [String: Double] = [:]
        for (k, v) in rows { byKey[k] = v }
        return javaHashMapOrder(rows.map { $0.0 }).reduce(0.0) { $0 + (byKey[$1] ?? 0) }
    }

    /// Unciv GameInfo.recordRankingStats – called after every turn.
    func recordRankingStats() {
        for i in civs.indices where civs[i].isMajor && civs[i].isAlive {
            // Unciv: "Force uses a transient cache that is not invalidated on combat losses during other civs' turns"
            resetMilitaryMightCache(civs[i].id)
            var row: [String: Int] = [:]
            for t in GameState.allRankingTypes { row[t] = statForRanking(civs[i], t) }
            civs[i].statsHistory[turn - 1] = row   // Unciv CivRankingHistory: keyed by gameInfo.turns before the increment (ours is one ahead)
        }
    }

    // MARK: Unciv VictoryManager milestones
    func milestoneCompleted(_ milestone: String, by civ: Civilization) -> Bool {
        let u = Unique(milestone)
        switch u.pattern {
        case "Build []": return cities(of: civ.id).contains { $0.buildings.contains(u.params[0]) }
        case "Anyone should build []": return cities.contains { $0.buildings.contains(u.params[0]) }
        case "Become the world religion":
            // Unciv WorldReligion: religion enabled, we founded one, and it is the majority religion for every living
            // major civ (ReligionManager.isMajorityReligionForCiv: in more than half - integer half - of its cities)
            guard religionEnabled, let r = civ.religionName else { return false }
            return majorCivs.filter { $0.isAlive }.allSatisfy { other in
                let own = cities(of: other.id)
                return own.filter { majorityReligion(of: $0) == r }.count > own.count / 2
            }
        case "Have more [] than each player's []":
            // Unciv MoreCountableThanEachPlayer: every other living major has less (getMoreCountableThanOtherCivPercent > 100)
            let relevant = civs.filter { $0.id != civ.id && $0.isMajor && $0.isAlive }
            return !relevant.isEmpty && relevant.allSatisfy { other in
                let countable1 = countable(u.params[0], UniqueContext(civId: civ.id)) ?? 0
                let countable2 = countable(u.params[1], UniqueContext(civId: other.id)) ?? 0
                let percent: Float = countable2 <= 0 ? (countable1 > countable2 ? 100.1 : 0) : Float(countable1) / Float(countable2) * 100
                return percent > 100
            }
        case "Have at least [] []":   // Unciv HaveCountable
            return (countable(u.params[1], UniqueContext(civId: civ.id)) ?? 0) >= (Int(u.params[0]) ?? 0)
        case "Add all [] in capital": let p = spaceshipProgress(civ); return p.needed > 0 && p.have >= p.needed
        case "Complete [] Policy branches": return civ.completedBranches >= (Int(u.params[0]) ?? 5)
        case "Capture all capitals":
            // Unciv Milestone: original capitals of major civs owned == civs that still have one or can still found one
            let isMajorCapital: (City) -> Bool = { $0.isOriginalCapital && (self.civ($0.originalOwner)?.isMajor ?? false) }
            let owned = cities(of: civ.id).filter(isMajorCapital).count
            let potential = Set(cities.filter(isMajorCapital).map { $0.originalOwner }).union(majorCivs.filter { !isDefeated($0) }.map { $0.id })
            return owned == potential.count
        case "Destroy all players": return majorCivs.filter { $0.isAlive }.count == 1 && civ.isAlive
        case "Win diplomatic vote": return civ.hasEverWonDiplomaticVote
        case "Have highest score after max turns":
            // Unciv ScoreAfterTimeOut: `gameInfo.turns >= maxTurns` (uncivTurns, zero-based) and the highest score of
            // every civilization - city-states and barbarians too, so one of them on top wins nobody the game (first on ties)
            guard uncivTurns >= settings.maxTurns else { return false }
            var best: Civilization? = nil
            for c in civs where best == nil || totalScore(c) > totalScore(best!) { best = c }   // Unciv maxByOrNull { calculateTotalScore() }: the Double, not its Int
            return best?.id == civ.id
        default: return false
        }
    }
    /// Unciv Milestone.getVictoryScreenButtonHeaderText (progress text for a milestone). `completed` is Unciv's
    /// `completionStatus == Completed` (always false on the global screen): a completed milestone shows its full count.
    func milestoneText(_ milestone: String, for civ: Civilization, completed: Bool) -> String {
        let u = Unique(milestone)
        switch u.pattern {
        // Unciv BuildingBuiltGlobally, WinDiplomaticVote, ScoreAfterTimeOut, BuiltBuilding: the description alone
        case "Build []", "Anyone should build []", "Win diplomatic vote", "Have highest score after max turns": return L(milestone)
        case "Complete [] Policy branches":
            let toDo = u.params[0]
            let done = completed ? toDo : "\(civ.completedBranches)"   // Unciv getCompletedPolicyBranchesCount
            return L("{\(milestone)} (\(done)/\(toDo))")
        case "Have at least [] []":
            // Unciv HaveCountable: getCountableDone capped at getCountableToDo
            let toDo = Int(u.params[0]) ?? 0
            let done = completed ? toDo : min(countable(u.params[1], UniqueContext(civId: civ.id)) ?? 0, toDo)
            return L("{\(milestone)} (\(done)/\(toDo))")
        case "Capture all capitals":
            // Unciv: originalMajorCapitalsOwned / civsWithPotentialCapitalsToOwn - the predicate of hasBeenCompletedBy,
            // ourselves included on both sides, so a new game reads (1/N)
            let isMajorCapital: (City) -> Bool = { $0.isOriginalCapital && (self.civ($0.originalOwner)?.isMajor ?? false) }
            let toDo = Set(cities.filter(isMajorCapital).map { $0.originalOwner }).union(majorCivs.filter { !isDefeated($0) }.map { $0.id }).count
            let done = completed ? toDo : cities(of: civ.id).filter(isMajorCapital).count
            return shouldHideCivCount(civ) ? L("{\(milestone)} (\(done)/?)") : L("{\(milestone)} (\(done)/\(toDo))")
        case "Destroy all players":
            // Unciv Milestone: (done/toDo), toDo = every major civ except ourselves
            let toDo = civs.filter { $0.isMajor }.count - 1
            let done = completed ? toDo : toDo - majorCivs.filter { $0.id != civ.id }.count
            return shouldHideCivCount(civ) ? L("{\(milestone)} (\(done)/?)") : L("{\(milestone)} (\(done)/\(toDo))")
        case "Add all [] in capital":
            // Unciv: toDo = requiredSpaceshipPartsAsCounter.sumValues(); done = toDo minus what is left once our parts
            // are removed from it - Counter.remove keeps negative counts, so that is every part in the capital
            let toDo = spaceshipProgress(civ).needed
            let done = civ.spaceshipParts.values.reduce(0, +)
            return L("{\(milestone)} (\(done)/\(toDo))")
        default: return milestone
        }
    }
}
