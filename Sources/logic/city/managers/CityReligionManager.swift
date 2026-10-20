// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv Constants.noReligionName: the pressure key of the citizens that follow no religion. It is the key a save
/// carries, so a city loaded from Unciv already holds it; a second, home-made key counted its pressure twice.
let noReligionName = "The religion of TheLegend27"

/// Mirror of Unciv `logic/city/managers/CityReligionManager.kt`: the faith of one city - its followers, its pressure, and what spreads it.
extension GameState {
    // MARK: followers
    /// Unciv CityReligionManager.followers: a transient FIELD (`@Transient private val followers: Counter<String>`),
    /// written only by updateNumberOfFollowers - at load (setTransients), and after every pressure or population
    /// change that goes through addPressure / removeAllPressuresExceptFor / updatePressureOnPopulationChange /
    /// removeUnknownPantheons / getAffectedBySurroundingCities. Between CityPopulationManager.addPopulation's
    /// `population += changedAmount` and its updatePressureOnPopulationChange it is STALE: the new citizen is placed
    /// (autoAssignPopulation → cityStats.update) with the old followers read against the new population, and the
    /// religion the new citizens' pressure goes to is picked the same way. A city not yet in the cache (just loaded or
    /// founded) is computed from its pressures, as setTransients does.
    func followers(of city: City) -> [String: Int] {
        if let cached = religionFollowersCache[city.id] { return cached }
        let fresh = computeFollowers(city)
        religionFollowersCache[city.id] = fresh.counts
        religionFollowersOrderCache[city.id] = fresh.order
        return fresh.counts
    }

    /// Unciv CityReligionManager.getNumberOfFollowers() for the state dump (App/StateDump.swift): what followers(of:)
    /// answers, without filling the cache - a dump that wrote it would make the game's next read fresher than Unciv's.
    func followersWithoutCaching(of city: City) -> [String: Int] {
        religionFollowersCache[city.id] ?? computeFollowers(city).counts
    }

    /// Unciv CityReligionManager.updateNumberOfFollowers: noReligionName pressure (100 by default) takes part, integer pressure per follower,
    /// leftover citizens go one by one to the largest remainder; noReligionName followers are dropped
    private func computeFollowers(_ city: City) -> (counts: [String: Int], order: [String]) {
        guard city.population > 0 else { return ([:], []) }
        // `pressures` in its Counter order; noReligionName (clearAllPressures, 100) heads it when a city lacks it
        var keys = city.orderedPressureKeys.filter { Int(city.religionPressure[$0] ?? 0) != 0 }
        var pressures: [String: Int] = [:]
        for k in keys { pressures[k] = Int(city.religionPressure[k]!) }
        if pressures[noReligionName] == nil { pressures[noReligionName] = 100; keys.insert(noReligionName, at: 0) }
        let perFollower = pressures.values.reduce(0, +) / city.population
        // `followers` is a Counter: `followers.add(religion, n)` inserts in the pressures walk (a 0 is not stored),
        // a leftover citizen's `add(key, 1)` appends a religion not yet in it. Its counts are Kotlin Ints: a city whose
        // population outnumbers its pressures (the console's `city setpop`) has a pressurePerFollower of 0, and
        // `(pressure.toFloat() / 0).toInt()` is Int.MAX_VALUE, which the sums below wrap - Swift's Int(inf) stopped the app
        var out: [String: Int] = [:]
        var order: [String] = []
        func add(_ k: String, _ n: Int) {
            // Counter.add: put(key, get(key) + value), and a put of 0 removes the key
            let v = Int32(truncatingIfNeeded: out[k] ?? 0) &+ Int32(truncatingIfNeeded: n)
            if v == 0 { if out.removeValue(forKey: k) != nil { order.removeAll { $0 == k } }; return }
            if out[k] == nil { order.append(k) }
            out[k] = Int(v)
        }
        var remaindersInPressureOrder: [(key: String, value: Float)] = []
        for r in keys {
            let p = pressures[r]!
            let n = kotlinToInt(Float(p) / Float(perFollower))
            add(r, n)
            remaindersInPressureOrder.append((r, Float(p) - Float(Int32(truncatingIfNeeded: n) &* Int32(truncatingIfNeeded: perFollower))))
        }
        // remainders is a java.util.HashMap<String, Float> filled in the pressures walk: it iterates bucket by bucket,
        // each bucket in insertion order - and maxByOrNull keeps the first maximum of that walk
        var remainders = remaindersInPressureOrder.enumerated().sorted { a, b in
            let ba = javaHashMapBucket(a.element.key), bb = javaHashMapBucket(b.element.key)
            return ba != bb ? ba < bb : a.offset < b.offset
        }.map { $0.element }
        var unallocated = Int(Int32(truncatingIfNeeded: city.population) &- out.values.reduce(Int32(0)) { $0 &+ Int32(truncatingIfNeeded: $1) })
        while unallocated > 0 {
            guard var best = remainders.indices.first else { add(noReligionName, unallocated); break }
            for i in remainders.indices where remainders[i].value > remainders[best].value { best = i }
            add(remainders[best].key, 1)
            remainders[best].value = 0
            unallocated -= 1
        }
        out.removeValue(forKey: noReligionName)   // followers.remove(noReligionName)
        order.removeAll { $0 == noReligionName }
        let kept = out.filter { $0.value != 0 }   // a Counter holds no 0 - and keeps what a wrapped sum left below it
        return (kept, order.filter { kept[$0] != nil })
    }

    /// The bucket a String key lands in within a default-sized java.util.HashMap (16 slots): String.hashCode, spread
    private func javaHashMapBucket(_ s: String) -> Int {
        var h: Int32 = 0
        for u in s.utf16 { h = h &* 31 &+ Int32(u) }
        let x = UInt32(bitPattern: h)
        return Int((x ^ (x >> 16)) & 15)
    }

    /// Unciv CityReligionManager.triggerReligionAdoption: the owner is always told; the founder's first-adoption stats only once per city
    func triggerReligionAdoption(cityId: Int, _ religion: String) {
        guard let ci = cityIndex(cityId) else { return }
        religionAdoptionEffects(cities[ci], religion)
        if let cj = cityIndex(cityId) { cities[cj].religionsAtSomePointAdopted.insert(religion) }
    }

    /// triggerReligionAdoption's notifications and grants, read from a City value - the live city's, or the dead City
    /// object a city razed this turn still is (razedCityReligionEndTurn). The caller records the religion as adopted.
    private func religionAdoptionEffects(_ city: City, _ religion: String) {
        notify(city.civId, "Your city [\(city.name)] was converted to [\(religion)]!", category: .Religion, icons: ["Faith"], coord: city.coord)
        if city.religionsAtSomePointAdopted.contains(religion) { return }
        if let owner = religionOwner(religion), let oi = civIndex(owner.id) {
            let adoption = founderUniques(for: owner.id).filter { $0.pattern == "[] when a city adopts this religion for the first time" || $0.pattern == "[] when a city adopts this religion for the first time (modified by game speed)" }
            if !adoption.isEmpty {
                var total = Stats()
                for u in adoption {
                    guard let st = u.stats else { continue }
                    let bySpeed = u.pattern.hasSuffix("(modified by game speed)") || u.conditionals.contains { $0.pattern == "(modified by game speed)" }
                    total += st * (bySpeed ? speed.modifier : 1)
                }
                civs[oi].gold += Double(Int(total.gold)); goldTrace(civs[oi].id, Double(Int(total.gold))); civs[oi].faithStored += Double(Int(total.faith)); civs[oi].cultureStored += Double(Int(total.culture))
                if Int(total.science) != 0 { addScience(civId: owner.id, Int(total.science)) }
                let text = total.uncivText   // Unciv "[$statsGranted]": Stats.toString of the speed-scaled sum ("+67 Gold" on Quick)
                if civs[oi].explored.contains(city.coord) { notify(owner.id, "You gained [\(text)] as your religion was spread to [\(city.name)]", category: .Religion, icons: ["Faith"], coord: city.coord) }
                else { notify(owner.id, "You gained [\(text)] as your religion was spread to an unknown city", category: .Religion, icons: ["Faith"]) }
            }
        }
    }

    /// Unciv CityReligionManager.removeAllPressuresExceptFor: keeps the religion and noReligionName (100 when it had none)
    func removeAllPressuresExceptFor(cityIndex ci: Int, _ religion: String) {
        let old = cities[ci].religionPressure
        let atheism = old[noReligionName] ?? 0
        // clearAllPressures (noReligionName 100, first), `add(religion, pressure)`, then atheism put in its place
        cities[ci].religionPressure = [:]
        cities[ci].religionPressure[noReligionName] = 100
        if let p = old[religion] { cities[ci].religionPressure[religion] = p }
        if atheism != 0 { cities[ci].religionPressure[noReligionName] = atheism }
        updateNumberOfFollowers(cityIndex: ci)
    }

    /// Unciv CityReligionManager.addPressure: nothing without religion; the pressure, then (by default) updateNumberOfFollowers
    func addPressure(cityIndex ci: Int, _ religion: String, _ amount: Int, shouldUpdateFollowers: Bool = true) {
        guard religionEnabled else { return }
        if cities[ci].religionPressure[noReligionName] == nil { cities[ci].religionPressure[noReligionName] = 100 }   // Unciv clearAllPressures at construction
        cities[ci].religionPressure[religion, default: 0] += Double(amount)
        if shouldUpdateFollowers { updateNumberOfFollowers(cityIndex: ci) }
    }

    /// Unciv CityReligionManager.updateNumberOfFollowers(checkForReligionAdoption): the old majority and followers are
    /// the stored field's; the followers are recounted (none at population 0, and then nothing else happens); on a new
    /// majority the adoption, on any majority change the civ's resources ("follower uniques can provide resources"),
    /// and on changed followers the city's stats - in that order.
    func updateNumberOfFollowers(cityIndex ci: Int, checkForReligionAdoption: Bool = true) {
        let cityId = cities[ci].id
        let oldMajority = checkForReligionAdoption ? majorityReligion(of: cities[ci]) : nil
        let previousFollowers = followers(of: cities[ci])
        let fresh = computeFollowers(cities[ci]); religionFollowersCache[cityId] = fresh.counts; religionFollowersOrderCache[cityId] = fresh.order
        guard cities[ci].population > 0, checkForReligionAdoption else { return }
        let newMajority = majorityReligion(of: cities[ci])
        if oldMajority != newMajority, let m = newMajority { triggerReligionAdoption(cityId: cityId, m) }
        if oldMajority != newMajority, let cj = cityIndex(cityId) { updateCivResources(cities[cj].civId) }
        if let cj = cityIndex(cityId), followers(of: cities[cj]) != previousFollowers { updateCityStats(cityId, reason: "CityReligionManager.updateNumberOfFollowers") }
    }

    /// Unciv CityReligionManager.updatePressureOnPopulationChange: new citizens bring 100 pressure each to the majority
    /// religion (read from the stored followers against the new population) or to noReligionName; a loss only recounts.
    func updatePressureOnPopulationChange(cityIndex ci: Int, _ populationChangeAmount: Int) {
        let majority = majorityReligion(of: cities[ci]) ?? noReligionName
        if populationChangeAmount > 0 { addPressure(cityIndex: ci, majority, 100 * populationChangeAmount) }
        else { updateNumberOfFollowers(cityIndex: ci) }
    }

    /// Unciv CityReligionManager.getSpreadRange: 10 + the city's and the founder's "Religion naturally spreads to cities [] tiles away"
    func religionSpreadRange(_ city: City, religion: String) -> Int {
        var range = 10
        let ctx = UniqueContext(civId: city.civId, city: city)
        for u in cityUniquesCivFirst(city) where u.pattern == "Religion naturally spreads to cities [] tiles away" && conditionalsHold(u, ctx) { range += u.int(0) }
        if let owner = religionOwner(religion) { for u in founderUniques(for: owner.id) where u.pattern == "Religion naturally spreads to cities [] tiles away" { range += u.int(0) } }
        return range
    }

    /// Unciv CityReligionManager.pressureAmountToAdjacentCities: base pressure × city and founder spread-strength uniques whose city filter matches the pressured city, truncated
    func pressureToAdjacentCity(from source: City, religion: String, to target: City) -> Int {
        var pressure = Float(speed.religiousPressureAdjacentCity)   // Unciv: pressureFromAdjacentCities.toFloat(), Float *= toPercent()
        let ctx = UniqueContext(civId: source.civId, city: source)
        func applies(_ u: Unique) -> Bool { u.pattern == "[]% Natural religion spread" || (u.pattern == "[]% Natural religion spread []" && cityMatchesFilter(u.param(1), city: target, viewer: target.civId)) }
        for u in cityUniquesCivFirst(source) where applies(u) && conditionalsHold(u, ctx) { pressure *= Float(Stats.toPercent(u.double(0))) }
        if let owner = religionOwner(religion) { for u in founderUniques(for: owner.id) where applies(u) && conditionalsHold(u, UniqueContext(civId: owner.id)) { pressure *= Float(Stats.toPercent(u.double(0))) } }
        pressure *= Float(vpLeagueReligionPressure(religion))   // VP: World Religion spreads 25% faster
        return Int(pressure)
    }

    func majorityReligion(of city: City) -> String? {
        let f = followers(of: city)
        var top: (name: String, count: Int)? = nil
        // Unciv `followers.maxByOrNull { it.value }`: the Counter's insertion order, the first maximum kept
        let order = religionFollowersOrderCache[city.id] ?? f.keys.sorted()
        for k in order + f.keys.filter({ !order.contains($0) }).sorted() {
            let v = f[k] ?? 0
            if top == nil || v > top!.count { top = (k, v) }
        }
        guard let best = top, best.count >= city.population / 2 else { return nil }   // Unciv getMajorityReligionName
        return best.name
    }

    func religionIsMajor(_ name: String?) -> Bool { name != nil && religionOwner(name!) != nil }

    func citiesFollowing(_ religion: String) -> [City] { cities.filter { majorityReligion(of: $0) == religion } }
    /// Unciv CityReligionManager.getPressureDeficit
    func pressureDeficit(of city: City, religion: String) -> Double {
        // Unciv getPressureDeficit: the majority religion's pressure minus ours
        (majorityReligion(of: city).flatMap { city.religionPressure[$0] } ?? 0) - (city.religionPressure[religion] ?? 0)
    }

    func globalFollowers(of religion: String) -> Int { cities.reduce(0) { $0 + (followers(of: $1)[religion] ?? 0) } }

    /// Unciv StatsFromGlobalFollowers: only followers in cities matching the belief's cityFilter (viewer = founder) count.
    func globalFollowers(of religion: String, filter: String, viewer: Int) -> Int { cities.reduce(0) { $0 + (cityMatchesFilter(filter, city: $1, viewer: viewer) ? (followers(of: $1)[religion] ?? 0) : 0) } }

    /// Unciv CityPopulationManager.addPopulation → updatePressureOnPopulationChange: +100 pressure per new citizen for the majority religion (or noReligionName)
    func addPopulation(cityIndex idx: Int, _ count: Int) {
        _ = followers(of: cities[idx])   // Unciv's followers field holds the count from before this change
        let changed = max(count, 1 - cities[idx].population)
        cities[idx].population += changed
        if GameState.evlogOn, changed != 0 { ev(cities[idx].civId, "CITY_POP", EvLog.name(cities[idx].name), String(cities[idx].population)) }
        // A citizen more or less changes the empire's happiness at once, and the reassignment just below reads it:
        // Unciv's growth penalty ([-75]% growth between -10 and -1 Happiness) turns on the moment the city grows.
        // Leaving the cached value in place meant the new citizen was placed as though the empire were still content.
        invalidateHappiness(cities[idx].civId)
        // (Unciv addPopulation does NOT raise shouldReassignPopulation: only CityPopulationManager.nextTurn's growth does.)
        // Unciv places the citizen immediately: a gain is assigned to the best free tile, a loss gives one up.
        let id = cities[idx].id
        // Unciv addPopulation branches on the free population and runs ONE path:
        //     if (freePopulation < 0) { unassignExtraPopulation(); city.cityStats.update() }
        //     else autoAssignPopulation()      // which updates twice by itself
        // Ours ran an unconditional `defer { updateCityStats }` on top of whichever path it took, so a city
        // that grew was updated three times where the reference updates it twice. Counted on `settled`: the
        // happiness field is rewritten 55.2 times a turn here against the reference's 36.9, and this is one
        // of the places the extra ones come from.
        let free = cities[idx].population - cities[idx].workedTiles.count - cities[idx].specialists.values.reduce(0, +)
        if free < 0 { unassignExtraPopulation(cityId: id); updateCityStats(id, reason: "CityReligionManager:9087") }
        else { assignWorkers(cityId: id, onlyFreePopulation: true, why: "CityReligionManager:9160") }
        // Unciv: `if (isReligionEnabled()) city.religion.updatePressureOnPopulationChange(changedAmount)` - for a loss too
        if religionEnabled, let ci = cityIndex(id) { updatePressureOnPopulationChange(cityIndex: ci, changed) }
    }

    /// Beliefs that apply inside a city: follower beliefs of its majority religion, or the pantheon beliefs when a pantheon is the majority.
    func religionUniques(for city: City) -> [Unique] {
        guard religionEnabled else { return [] }
        var out: [Unique] = []
        if let r = majorityReligion(of: city), let owner = religionOwner(r) {
            for b in owner.religionBeliefs { if let def = rs.beliefs[b], def.type == "Follower" || def.type == "Pantheon" { out += def.uniqueObjects.from(.followerBelief, b) } }
        } else if let r = majorityReligion(of: city), let founder = civs.first(where: { $0.pantheonBelief == r }) {
            // Unciv: a pantheon's beliefs apply only where it is the majority religion
            for b in [r] + founder.religionBeliefs.filter({ $0 != r }) { if let def = rs.beliefs[b], def.type == "Pantheon" { out += def.uniqueObjects.from(.followerBelief, b) } }
        }
        return out
    }

    // MARK: spreading
    /// Unciv ReligionManager.maySpreadReligionNow (+ maySpreadReligionAtAll): on a tile of a city whose majority is another
    /// faith and that no inquisitor of another religion protects
    func canSpread(_ unit: Unit, at c: HexCoord, needMovement: Bool = true) -> Bool {
        guard religionEnabled, civ(unit.civId)?.isMajor == true, unit.charges > 0, let r = unit.religion, religionIsMajor(r), !needMovement || unit.movementLeft > 0, let city = city(at: c) else { return false }
        guard map[unit.coord]?.ownerCivId != nil, owningCity(unit.coord)?.id == city.id else { return false }   // Unciv: tile.getCity()
        if majorityReligion(of: city) == r { return false }
        return !isProtectedByInquisitor(city, fromReligion: r)
    }

    /// Unciv CityReligionManager.isProtectedByInquisitor: a unit of another religion (any, without one) next to the centre prevents spreading
    func isProtectedByInquisitor(_ city: City, fromReligion: String? = nil) -> Bool {
        map.tilesWithin(city.coord, radius: 1).contains { c in
            units(at: c).contains { u in u.religion != nil && (fromReligion == nil || u.religion != fromReligion) && u.def.uniques.contains("Prevents spreading of religion to the city it is next to") }
        }
    }

    func spreadReligion(unitId: Int, to cityId: Int) {
        guard let ui = unitIndex(unitId), let ci = cityIndex(cityId), let r = units[ui].religion, canSpread(units[ui], at: cities[ci].coord) else { return }
        // Unciv getPressureAddedFromSpread: base religious strength × every spread strength unique of the unit and its civ
        var strength = Double(units[ui].def.religiousStrength)
        let ctx = UniqueContext(civId: units[ui].civId, unit: units[ui])
        let spreaderUniques = units[ui].def.uniqueObjects + units[ui].promotionUniques + civUniques(units[ui].civId)
        for u in spreaderUniques where u.pattern == "[]% Spread Religion Strength" && conditionalsHold(u, ctx) { strength *= 1 + u.double(0) / 100 }
        // Unciv StatsWhenSpreading: the spreading unit's uniques, counting followers of other religions before the pressure is added
        let othersBefore = followers(of: cities[ci]).filter { $0.key != r }.values.reduce(0, +)
        if let ui0 = civIndex(units[ui].civId) {
            for u in spreaderUniques where u.pattern == "When spreading religion to a city, gain [] times the amount of followers of other religions as []" {
                let amount = Double(othersBefore * u.int(0))
                if u.param(1) == "Gold" { civs[ui0].gold += amount } else if u.param(1) == "Science" { addScience(civId: civs[ui0].id, Int(amount)) } else if u.param(1) == "Culture" { civs[ui0].cultureStored += amount } else if u.param(1) == "Faith" { civs[ui0].faithStored += amount }
            }
        }
        let previousMajority = majorityReligion(of: cities[ci])
        let spreaderCiv = units[ui].civId, unitName = units[ui].name
        let removesOthers = units[ui].def.uniques.contains("Removes other religions when spreading religion")
        units[ui].actedThisTurn = true
        // Unciv UnitActionsReligion: addPressure (→ updateNumberOfFollowers: adoption, civ resources, city stats), then
        // "Removes other religions" keeps only this religion (and noReligionName) and recounts again. Ours wrote the
        // pressure directly and ran the adoption once at the end, with neither the resources nor the city stats.
        addPressure(cityIndex: ci, r, Int(strength))
        if removesOthers, let cj = cityIndex(cityId) { removeAllPressuresExceptFor(cityIndex: cj, r) }
        guard let cj = cityIndex(cityId) else { return }
        // Unciv UnitActionsReligion: the city owner learns who converted their city.
        let newMajority = majorityReligion(of: cities[cj])
        if previousMajority != newMajority, let n = newMajority, cities[cj].civId != spreaderCiv { notify(cities[cj].civId, "[\(civ(spreaderCiv)?.nation ?? "?")]'s [\(unitName)] has converted [\(cities[cj].name)] to [\(n)]!", category: .Religion) }   // Unciv: no icon, no location
        spreadReligionSideEffects(unitId: unitId)
        // Unciv: after activateSideEffects, and only when the city owner doesn't want our religion, i.e. it can still get its own
        if let ck = cityIndex(cityId), cities[ck].civId != spreaderCiv, remainingFoundableReligions() != 0 || civ(cities[ck].civId)?.religionName != nil { setFlag(cities[ck].civId, spreaderCiv, "SpreadReligionInOurCities", Int((30 * speed.modifier).rounded())) }
        invalidateHappiness()
    }

    /// Unciv UnitActionModifiers.activateSideEffects for "Can Spread Religion <for [n] movement> <[n] times> <after
    /// which this unit is consumed>": the movement cost through useMovementPoints (which also ends fortification),
    /// then the last use consumes the unit - its "upon expending" triggers and MapUnit.destroy - and any other use is
    /// counted. Our `charges` is Unciv's usagesLeft (the "[] times" plus the promotions' additional times).
    private func spreadReligionSideEffects(unitId: Int) {
        guard let ui = unitIndex(unitId) else { return }
        let spreadUnique = (units[ui].def.uniqueObjects + units[ui].promotionUniques).first { $0.pattern == "Can Spread Religion" }
        let movementCost: Double
        if spreadUnique?.conditionals.contains(where: { $0.pattern == "for all movement" }) == true { movementCost = maxMovement(of: units[ui]) }
        else { movementCost = spreadUnique?.conditionals.filter { $0.pattern == "for [] movement" || $0.pattern == "requires [] movement" }.map { Double($0.int(0)) }.max() ?? 1 }
        useMovementPoints(unitId, movementCost)
        guard let uj = unitIndex(unitId) else { return }
        let consumedAfterLastUse = spreadUnique?.conditionals.contains(where: { $0.pattern == "after which this unit is consumed" }) ?? true
        if units[uj].charges <= 1 && consumedAfterLastUse {
            units[uj].charges = 0
            consumeUnit(unitId)
            return
        }
        units[uj].charges -= 1
        units[uj].abilityToTimesUsed["Can Spread Religion", default: 0] += 1   // Unciv abilityToTimesUsed (also read by "if it hasn't used other actions yet")
    }

    /// `needMovement: false` is the button's visibility (Unciv getRemoveHeresyActions offers it without movement and
    /// only the action's `takeIf { canActivateSideEffects }` asks for a movement point), the default its use.
    func canRemoveHeresy(_ unit: Unit, at c: HexCoord, needMovement: Bool = true) -> Bool {
        // Unciv UnitActionsReligion.getRemoveHeresyAction: "if (religion.isPantheon()) return" — only a founded religion purges heresy
        guard religionEnabled, unit.def.canRemoveReligions, !needMovement || unit.movementLeft > 0, let city = city(at: c), city.civId == unit.civId, owningCity(unit.coord)?.id == city.id, let r = unit.religion, religionIsMajor(r) else { return false }   // Unciv: tile.getCity() is ours
        return city.religionPressure.keys.contains { $0 != r }
    }

    func removeHeresy(unitId: Int, cityId: Int) {
        guard let ui = unitIndex(unitId), let ci = cityIndex(cityId), let r = units[ui].religion, canRemoveHeresy(units[ui], at: cities[ci].coord) else { return }
        removeAllPressuresExceptFor(cityIndex: ci, r)   // Unciv: its updateNumberOfFollowers runs the adoption, resources and stats
        // Unciv UnitActionsReligion.removeHeresy: purging the holy religion's own Holy City restores it; purging another faith's Holy City strips it.
        if !cities[ci].isHolyCity, cities[ci].holyCityOf == r, let founder = religionOwner(r) {
            cities[ci].isHolyCity = true
            notify(founder.id, "An [\(units[ui].name)] has restored [\(cities[ci].name)] as the Holy City of your religion [\(religionDisplayName(r))]!", category: .Religion)   // Unciv: getReligionDisplayName, no icon, no location
        }
        else if cities[ci].isHolyCity, let holy = cities[ci].holyCityOf, holy != r, let founder = religionOwner(holy) {
            cities[ci].isHolyCity = false
            notify(founder.id, "An [\(units[ui].name)] has removed your religion [\(religionDisplayName(holy))] from its Holy City [\(cities[ci].name)]!", category: .Religion)   // Unciv: getReligionDisplayName, no icon, no location
        }
        // Unciv UnitActionModifiers.activateSideEffects(unit, "Can remove other religions from cities <..> <once>
        // <after which this unit is consumed>"): one movement point, then the only use consumes the unit.
        if let heresyUnique = units[ui].def.uniqueObjects.first(where: { $0.pattern == "Can remove other religions from cities" }) {
            activateActionSideEffects(unitId: unitId, unique: heresyUnique)
        } else {
            consumeUnit(unitId)
        }
        invalidateHappiness()
    }

    /// Natural spread: each city with a majority religion pushes pressure to cities within range.
    /// Unciv CityReligionManager.getAffectedBySurroundingCities, city by city (a city converted earlier this turn already spreads its new faith):
    /// holy city 5× pressure on itself, then every other city's major majority religion within its spread range; no inquisitor check
    /// Unciv CityReligionManager.getPressuresFromSurroundingCities: the pressure this city will receive next turn.
    func pressuresFromSurroundingCities(_ city: City) -> [String: Int] {
        var added: [String: Int] = [:]
        for (r, amount) in orderedPressuresFromSurroundingCities(city) { added[r, default: 0] += amount }
        return added
    }

    /// The same pressures in the order getAffectedBySurroundingCities adds them: the holy city's own first, then each
    /// other city in `gameInfo.getCities()` order (civ by civ, each civ's own list). Every addPressure writes one key
    /// into the `pressures` Counter (a LinkedHashMap), so a religion new to the city lands where it is first added -
    /// and that order decides the followers walk and getMajorityReligionName's first maximum. A religion met twice is
    /// summed into its first place.
    func orderedPressuresFromSurroundingCities(_ city: City) -> [(religion: String, amount: Int)] {
        var order: [(religion: String, amount: Int)] = []
        var at: [String: Int] = [:]
        func add(_ r: String, _ n: Int) {
            if let i = at[r] { order[i].amount += n } else { at[r] = order.count; order.append((r, n)) }
        }
        if city.isHolyCity, let r = city.holyCityOf { add(r, 5 * Int(speed.religiousPressureAdjacentCity)) }
        for other in civs.flatMap({ cities(of: $0.id) }) where other.id != city.id {
            guard let r = majorityReligion(of: other), religionIsMajor(r), other.coord.distance(to: city.coord) <= religionSpreadRange(other, religion: r) else { continue }
            add(r, pressureToAdjacentCity(from: other, religion: r, to: city))
        }
        return order
    }

    /// Unciv CityReligionManager.endTurn → getAffectedBySurroundingCities for ONE city, called from
    /// CityTurnManager.endTurn right after that city's population changed: a city converted earlier in the loop
    /// already spreads its new faith to the cities after it, in the civ's own city order (ours used to walk the
    /// global city array once the whole loop was over).
    func cityReligionEndTurn(cityId: Int) {
        guard religionEnabled, let idx = cityIndex(cityId) else { return }
        do {
            // Unciv getAffectedBySurroundingCities: every addPressure(..., false), in the order they come, then ONE
            // updateNumberOfFollowers - the adoption first, then updateCivResources ("follower uniques can provide
            // resources"), the city's own stats LAST.
            for (r, amount) in orderedPressuresFromSurroundingCities(cities[idx]) { addPressure(cityIndex: idx, r, amount, shouldUpdateFollowers: false) }
            updateNumberOfFollowers(cityIndex: idx)
        }
    }

    /// Unciv CityTurnManager.endTurn after `city.destroyCity()` for a city razed to the ground: nothing returns, and
    /// `if (isReligionEnabled()) city.religion.endTurn()` still runs on the dead City object - only the health block
    /// after it asks `city in city.civ.cities`. getAffectedBySurroundingCities adds the pressures of the cities still
    /// in the game (the dead one no longer is), then updateNumberOfFollowers recounts at the unchanged population: a
    /// new majority is announced to the razer and may pay the founder's first-adoption stats, a changed majority
    /// refreshes the razer's resources, changed followers run the dead city's cityStats.update, whose only lasting
    /// effect is its `civ.updateStatsForNextTurn()`. Our dead city is destroyedCitySnapshots' copy.
    func razedCityReligionEndTurn(cityId: Int) {
        guard religionEnabled, var snap = destroyedCitySnapshots[cityId] else { return }
        // updateNumberOfFollowers reads the stored followers field, which addPressure(..., false) leaves alone
        let oldMajority = majorityReligion(of: snap)
        let previousFollowers = followers(of: snap)
        // addPressure(..., false) each, in order: noReligionName first when the city has none (clearAllPressures)
        for (r, amount) in orderedPressuresFromSurroundingCities(snap) {
            if snap.religionPressure[noReligionName] == nil { snap.religionPressure[noReligionName] = 100 }
            snap.religionPressure[r, default: 0] += Double(amount)
        }
        destroyedCitySnapshots[cityId] = snap
        // updateNumberOfFollowers(checkForReligionAdoption = true)
        let fresh = computeFollowers(snap); religionFollowersCache[cityId] = fresh.counts; religionFollowersOrderCache[cityId] = fresh.order
        guard snap.population > 0 else { return }
        let newMajority = majorityReligion(of: snap)
        if oldMajority != newMajority, let m = newMajority {
            religionAdoptionEffects(snap, m)
            destroyedCitySnapshots[cityId]?.religionsAtSomePointAdopted.insert(m)
        }
        if oldMajority != newMajority { updateCivResources(snap.civId) }
        if fresh.counts != previousFollowers { updateStatsForNextTurn(snap.civId) }   // the dead city's cityStats.update()
    }

    func religionPressureTurn(for civId: Int) {
        guard religionEnabled else { return }
        // Inquisitor protection recomputed each turn.
        for i in cities.indices where cities[i].civId == civId {
            cities[i].inquisitorProtected = units.contains { $0.def.uniques.contains("Prevents spreading of religion to the city it is next to") && $0.coord.distance(to: cities[i].coord) <= 1 && $0.religion != nil }   // Unciv isProtectedByInquisitor(): any civ
        }
    }
}
