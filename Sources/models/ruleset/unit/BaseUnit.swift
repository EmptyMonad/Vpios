// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct UnitDef: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let unitType: String
    let movement: Int
    let strength: Int
    let rangedStrength: Int
    let range: Int
    let cost: Int
    let requiredTech: String?
    let obsoleteTech: String?
    let upgradesTo: String?
    let uniqueTo: String?
    let replaces: String?
    let uniques: [String]
    let uniqueObjects: [Unique]
    let requiredResource: String?
    let promotions: [String]
    let hurryCostModifier: Int
    let interceptRange: Int
    let religiousStrength: Int
    let attackSound: String?

    /// Unciv ICivilopediaText.civilopediaText: the flavour lines written for this object.
    var civilopediaText: [CivilopediaLine] = []
    private enum CodingKeys: String, CodingKey {
        case name, unitType, movement, strength, rangedStrength, range, cost, requiredTech, obsoleteTech, upgradesTo, uniqueTo, replaces, uniques, requiredResource, promotions, hurryCostModifier, interceptRange, religiousStrength, attackSound, civilopediaText
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        civilopediaText = try c.decodeIfPresent([CivilopediaLine].self, forKey: .civilopediaText) ?? []
        name = try c.decode(String.self, forKey: .name)
        unitType = try c.decode(String.self, forKey: .unitType)
        movement = try c.decodeIfPresent(Int.self, forKey: .movement) ?? 0   // Unciv BaseUnit.movement = 0
        strength = try c.decodeIfPresent(Int.self, forKey: .strength) ?? 0
        rangedStrength = try c.decodeIfPresent(Int.self, forKey: .rangedStrength) ?? 0
        range = try c.decodeIfPresent(Int.self, forKey: .range) ?? 2
        cost = try c.decodeIfPresent(Int.self, forKey: .cost) ?? -1
        requiredTech = try c.decodeIfPresent(String.self, forKey: .requiredTech)
        obsoleteTech = try c.decodeIfPresent(String.self, forKey: .obsoleteTech)
        upgradesTo = try c.decodeIfPresent(String.self, forKey: .upgradesTo)
        uniqueTo = try c.decodeIfPresent(String.self, forKey: .uniqueTo)
        replaces = try c.decodeIfPresent(String.self, forKey: .replaces)
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        uniqueObjects = uniques.map(Unique.init)
        requiredResource = try c.decodeIfPresent(String.self, forKey: .requiredResource)
        promotions = try c.decodeIfPresent([String].self, forKey: .promotions) ?? []
        hurryCostModifier = try c.decodeIfPresent(Int.self, forKey: .hurryCostModifier) ?? 0
        interceptRange = try c.decodeIfPresent(Int.self, forKey: .interceptRange) ?? 0
        religiousStrength = try c.decodeIfPresent(Int.self, forKey: .religiousStrength) ?? 0
        attackSound = try c.decodeIfPresent(String.self, forKey: .attackSound)
    }

    var isCivilian: Bool { strength == 0 }
    var isReligious: Bool { uniques.contains("Religious Unit") }
    var canFoundReligion: Bool { uniqueObjects.contains { $0.pattern == "May found a religion" } }
    var canEnhanceReligion: Bool { uniqueObjects.contains { $0.pattern == "May enhance a religion" } }
    /// "Can Spread Religion <for [2] movement> <[4] times> <after which this unit is consumed>"
    var spreadCharges: Int { uniqueObjects.first { $0.pattern == "Can Spread Religion" }?.conditionals.first { $0.pattern == "[] times" }?.int(0) ?? 0 }
    var canRemoveReligions: Bool { uniqueObjects.contains { $0.pattern == "Can remove other religions from cities" } }
    /// Unciv UniqueType.CanBePurchasedWithStat: "Can be purchased with [stat] [cityFilter]".
    func purchasableWith(_ stat: String) -> Bool { uniqueObjects.contains { $0.pattern == "Can be purchased with [] []" && $0.param(0) == stat } }
    var purchasableWithFaith: Bool { purchasableWith("Faith") }
    var canAirSweep: Bool { Ruleset.shared.unitTypes[unitType]?.uniques.contains("Can perform Air Sweep") ?? false }
    var cannotBeIntercepted: Bool { Ruleset.shared.unitTypes[unitType]?.uniques.contains("Cannot be intercepted") ?? false }
    var isInvisible: Bool { Ruleset.shared.unitTypes[unitType]?.uniques.contains("Invisible to non-adjacent units") ?? false }
    var passesImpassable: Bool { Ruleset.shared.unitTypes[unitType]?.uniques.contains("Can pass through impassable tiles") ?? false }
    var movementType: String { Ruleset.shared.unitTypes[unitType]?.movementType ?? "Land" }
    var isWater: Bool { movementType == "Water" }
    var isAir: Bool { movementType == "Air" }
    var isLand: Bool { movementType == "Land" }
    var isSpaceshipPart: Bool { uniques.contains("Spaceship part") }
    var mustSetUp: Bool { uniques.contains("Must set up to ranged attack") }
    var neverBarbarian: Bool { uniques.contains("Never appears as a Barbarian unit") }
    var isNuclear: Bool { uniqueObjects.contains { $0.pattern == "Nuclear weapon of Strength []" } }   // Unciv BaseUnit.isNuclearWeapon
    /// "Can instantly construct a [Academy] improvement <by consuming this unit>"
    var instantImprovement: String? { uniqueObjects.first { $0.pattern == "Can instantly construct a [] improvement" }?.param(0) }
    var greatPersonType: String? { uniqueObjects.first { $0.pattern == "Great Person - []" }?.param(0) ?? uniqueObjects.first { $0.pattern == "Is part of Great Person group []" }?.param(0) }
    var isRanged: Bool { rangedStrength > 0 }
    var isSettler: Bool { uniques.contains { $0.hasPrefix("Founds a new city") || $0.hasPrefix("Founds a new puppet city") } }   // Unciv FoundCity / FoundPuppetCity
    var isWorker: Bool { uniques.contains { $0.hasPrefix("Can build [Land] improvements") } }
    var isGreatPerson: Bool { greatPersonType != nil }   // Unciv BaseUnit.isGreatPerson: the unique, never the name

    /// Unciv BaseUnit.rulesetUniqueObjects (setRuleset): the unit's own uniques, then GlobalUniques.unitUniques, then
    /// its unit type's - what BaseUnit.hasUnique / getMatchingUniques read.
    var rulesetUniqueObjects: [Unique] { Ruleset.shared.unitRulesetUniques[name] ?? uniqueObjects }
    /// Unciv BaseUnit.isMilitary: `isRanged() || isMelee()`, i.e. any ranged or melee strength
    var isMilitaryUnit: Bool { rangedStrength > 0 || strength > 0 }
    /// Unciv BaseUnit.isCityFounder / the NoSettlerForOneCityPlayers test: hasUnique(FoundCity, IgnoreConditionals)
    var hasFoundCityUnique: Bool { rulesetUniqueObjects.contains { $0.pattern == "Founds a new city" } }
}

extension GameState {
    /// Unciv BaseUnit.matchesFilter (implements UniqueParameterType.BaseUnitFilter)
    func baseUnitMatchesFilter(_ u: UnitDef, _ filter: String, _ ctx: UniqueContext? = nil, multiFilter: Bool = true) -> Bool {
        func single(_ f: String) -> Bool {
            baseUnitMatchesSingleFilter(u, f, ctx) || hasTagUnique(u.rulesetUniqueObjects, f, ctx)
        }
        return multiFilter ? MultiFilter.multiFilter(filter, single) : single(filter)
    }

    /// Unciv BaseUnit.matchesSingleFilter
    func baseUnitMatchesSingleFilter(_ u: UnitDef, _ filter: String, _ ctx: UniqueContext? = nil) -> Bool {
        let empty = UniqueContext(civId: -1)
        func has(_ pattern: String) -> Bool { u.rulesetUniqueObjects.contains { $0.pattern == pattern && conditionalsHold($0, empty) } }
        switch filter {
        case "all", "All": return true
        case "Melee": return !u.isRanged && u.strength > 0
        case "Ranged": return u.isRanged
        case "Civilian": return !u.isMilitaryUnit
        case "Military": return u.isMilitaryUnit
        case "Land": return u.isLand
        case "Water": return u.isWater
        case "Air": return u.isAir
        case "non-air": return !u.isAir
        case "Nuclear Weapon": return u.rulesetUniqueObjects.contains { $0.pattern == "Nuclear weapon of Strength []" }   // IgnoreConditionals
        case "Great Person": return has("Great Person - []")
        case "Religious": return has("Religious Unit")
        default:
            if filter == u.unitType { return true }
            if filter == u.name { return true }
            if filter == u.replaces { return true }
            for tech in requiredTechs(requiredTech: u.requiredTech, uniques: u.rulesetUniqueObjects)
                where technologyMatchesFilter(tech, filter, ctx, multiFilter: false) { return true }
            // "military units" --> "Military", using invariant locale
            if filter.hasSuffix(" units") {
                let stem = String(filter.dropLast(" units".count)).lowercased()
                let adjective = stem.prefix(1).uppercased() + stem.dropFirst()
                if baseUnitMatchesFilter(u, adjective, nil, multiFilter: false) { return true }
            }
            return false
        }
    }
}

extension UnitDef {
    /// Unciv BaseUnit.getForceEvaluation / evaluateForce, in Float as there.
    var forceEvaluation: Int {
        let u = self
        if u.strength == 0 && u.rangedStrength == 0 { return 0 }
        // Kotlin Float.pow(Float) is `Math.pow(this.toDouble(), x.toDouble()).toFloat()`
        func kpow(_ a: Float, _ b: Float) -> Float { Float(pow(Double(a), Double(b))) }
        var power: Float = kpow(Float(u.strength), 1.5)
        var rangedPower: Float = kpow(Float(u.rangedStrength), 1.45)
        // Value ranged naval units less
        if u.isWater { rangedPower /= 2 }
        if rangedPower > 0 { power = rangedPower }
        power = power * kpow(Float(u.movement), 0.3)
        // hasUnique(SelfDestructs) in GameContext.EmptyState: only a unique whose modifiers are all of the Other kind
        if u.rulesetUniqueObjects.contains(where: { $0.pattern == "Self-destructs when attacking" && $0.conditionals.allSatisfy { GameState.otherModifierPatterns.contains($0.pattern) } }) { power /= 2 }
        if u.rulesetUniqueObjects.contains(where: { $0.pattern == "Nuclear weapon of Strength []" }) { power += 4000 }
        // rulesetUniqueObjects, then the uniques of the promotions it starts with
        let allUniques = u.rulesetUniqueObjects + u.promotions.flatMap { Ruleset.shared.promotions[$0]?.uniqueObjects ?? [] }
        // When we have multiple conditional strength bonuses, only the highest one counts - which in Unciv's
        // code is the LAST one matched: each branch overwrites the running bonus.
        var highestConditionalPowerBonus: Float = 1
        for unique in allUniques {
            switch unique.pattern {
            case "[]% Strength":
                let amount = unique.int(0)
                if amount <= 0 { continue }
                if unique.conditionals.contains(where: { $0.pattern == "vs [] units" }) {   // ConditionalVsUnits: a quarter of the bonus
                    highestConditionalPowerBonus = 1 + (Float(amount) / 4) / 100
                } else if unique.conditionals.contains(where: { ["vs cities", "when attacking", "when defending", "when fighting in [] tiles"].contains($0.pattern) }) {
                    highestConditionalPowerBonus = 1 + (Float(amount) / 2) / 100
                } else {
                    highestConditionalPowerBonus = 1 + Float(amount) / 100   // Static bonus
                }
            case "[]% Strength decreasing with distance from the capital":
                if unique.int(0) > 0 { power *= 1 + (Float(unique.int(0)) / 4) / 100 }
            case "May Paradrop to [] tiles up to [] tiles away":   // Paradrop - 25% bonus
                power *= 1.25
            case "Must set up to ranged attack":   // Must set up - 20 % penalty
                power /= 1.20
            case "[] additional attacks per turn":   // Extra attacks - 20% bonus per extra attack (if sufficient movement)
                let limit = u.isAir ? Int.max : u.movement - 1
                power *= 1 + (20 * Float(min(unique.int(0), limit))) / 100
            default: break
            }
        }
        power *= highestConditionalPowerBonus
        return Int(power)
    }
}
