// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Port of Unciv's DiplomacyManager / DiplomacyTurnManager / DeclareWar / Demand (opinion modifiers, flags,
/// friendships, denouncements, defensive pacts, embassies, demands, war and peace side effects).
/// Modifier values live in `Civilization.opinions[other][DiploModifier.rawValue]`, flags in `Civilization.diploFlags`.
enum DiploModifier: String, CaseIterable {
    case DeclaredWarOnUs, WarMongerer, CapturedOurCities, DeclaredFriendshipWithOurEnemies, BetrayedDeclarationOfFriendship,
         SignedDefensivePactWithOurEnemies, BetrayedDefensivePact, Denunciation, DenouncedOurAllies,
         RefusedToNotSettleCitiesNearUs, RefusedToNotSpreadReligionToUs, RefusedToNotSendingSpiesToUs, RefusedToPromiseNotToAttackUs,
         BetrayedPromiseToNotSettleCitiesNearUs, BetrayedPromiseToNotSpreadReligionToUs, BetrayedPromiseToNotSendingSpiesToUs,
         BetrayedPromiseToNotAttackUs, BetrayedPromiseToNotAttackOtherCiv, UnacceptableDemands, UsedNuclearWeapons, StealingTerritory,
         DestroyedProtectedMinor, AttackedProtectedMinor, AttackedAlliedMinor, BulliedProtectedMinor, SidedWithProtectedMinor, SpiedOnUs,
         StoleOurAlly, EstablishedEmbassy, ReceivedEmbassy, SharedEmbassies, YearsOfPeace, SharedEnemy, LiberatedCity,
         DeclarationOfFriendship, DeclaredFriendshipWithOurAllies, DefensivePact, SignedDefensivePactWithOurAllies, DenouncedOurEnemies,
         OpenBorders, FulfilledPromiseToNotSettleCitiesNearUs, FulfilledPromiseToNotSpreadReligion, FulfilledPromiseToNotSpy,
         FulfilledPromiseToNotAttackUs, GaveUsUnits, GaveUsGifts, ReturnedCapturedUnits, BelieveSameReligion

    /// Unciv DiplomaticModifiers.text
    var text: String {
        switch self {
        case .DeclaredWarOnUs: return "You declared war on us!"
        case .WarMongerer: return "Your warmongering ways are unacceptable to us."
        case .CapturedOurCities: return "You have captured our cities!"
        case .DeclaredFriendshipWithOurEnemies: return "You have declared friendship with our enemies!"
        case .BetrayedDeclarationOfFriendship: return "Your so-called 'friendship' is worth nothing."
        case .SignedDefensivePactWithOurEnemies: return "You have signed a defensive pact with our enemy!"
        case .BetrayedDefensivePact: return "Your so-called 'defensive pact' is worth nothing."
        case .Denunciation: return "You have publicly denounced us!"
        case .DenouncedOurAllies: return "You have denounced our allies"
        case .RefusedToNotSettleCitiesNearUs: return "You refused to stop settling cities near us"
        case .RefusedToNotSpreadReligionToUs: return "You refused to stop spreading religion to us"
        case .RefusedToNotSendingSpiesToUs: return "You refused to stop spying on us"
        case .RefusedToPromiseNotToAttackUs: return "You declared war on us after we questioned the positioning of your military."
        case .BetrayedPromiseToNotSettleCitiesNearUs: return "You betrayed your promise to not settle cities near us"
        case .BetrayedPromiseToNotSpreadReligionToUs: return "You betrayed your promise to not spread your religion to us"
        case .BetrayedPromiseToNotSendingSpiesToUs: return "You betrayed your promise to stop spying on us"
        case .BetrayedPromiseToNotAttackUs: return "You betrayed your promise to not attack us!"
        case .BetrayedPromiseToNotAttackOtherCiv: return "You were observed betraying your promise to not declare war!"
        case .UnacceptableDemands: return "Your arrogant demands are in bad taste"
        case .UsedNuclearWeapons: return "Your use of nuclear weapons is disgusting!"
        case .StealingTerritory: return "You have stolen our lands!"
        case .DestroyedProtectedMinor: return "You destroyed City-States that were under our protection!"
        case .AttackedProtectedMinor: return "You attacked City-States that were under our protection!"
        case .AttackedAlliedMinor: return "You attacked our allied City-States!"
        case .BulliedProtectedMinor: return "You demanded tribute from City-States that were under our protection!"
        case .SidedWithProtectedMinor: return "You sided with a City-State over us"
        case .SpiedOnUs: return "You spied on us!"
        case .StoleOurAlly: return "You took the alliance we had with a City-State"
        case .EstablishedEmbassy: return "We have an embassy in your capital"
        case .ReceivedEmbassy: return "You have an embassy in our capital"
        case .SharedEmbassies: return "We have shared embassies"
        case .YearsOfPeace: return "Years of peace have strengthened our relations."
        case .SharedEnemy: return "Our mutual military struggle brings us closer together."
        case .LiberatedCity: return "We applaud your liberation of conquered cities!"
        case .DeclarationOfFriendship: return "We have signed a public declaration of friendship"
        case .DeclaredFriendshipWithOurAllies: return "You have declared friendship with our allies"
        case .DefensivePact: return "We have signed a promise to protect each other."
        case .SignedDefensivePactWithOurAllies: return "You have signed a defensive pact with our ally"
        case .DenouncedOurEnemies: return "You have denounced our enemies"
        case .OpenBorders: return "Our open borders have brought us closer together."
        case .FulfilledPromiseToNotSettleCitiesNearUs: return "You fulfilled your promise to stop settling cities near us!"
        case .FulfilledPromiseToNotSpreadReligion: return "You fulfilled your promise to stop spreading religion to us!"
        case .FulfilledPromiseToNotSpy: return "You fulfilled your promise to stop spying on us!"
        case .FulfilledPromiseToNotAttackUs: return "You fulfilled your promise to not attack us!"
        case .GaveUsUnits: return "You gave us units!"
        case .GaveUsGifts: return "We appreciate your gifts"
        case .ReturnedCapturedUnits: return "You returned captured units to us"
        case .BelieveSameReligion: return "We believe in the same religion"
        }
    }
}

/// Unciv Demand: "please stop X" requests between major civs.
enum Demand: String, CaseIterable, Codable {
    case DontSpyOnUs, DoNotSpreadReligion, DoNotSettleNearUs, DoNotAttackUs
    var agreedToDemand: String { switch self { case .DontSpyOnUs: return "AgreedToNotSendSpies"; case .DoNotSpreadReligion: return "AgreedToNotSpreadReligion"; case .DoNotSettleNearUs: return "AgreedToNotSettleNearUs"; case .DoNotAttackUs: return "AgreedToNotAttackUs" } }
    var violationOccurred: String { switch self { case .DontSpyOnUs: return "DiscoveredSpiesInOurCities"; case .DoNotSpreadReligion: return "SpreadReligionInOurCities"; case .DoNotSettleNearUs: return "SettledCitiesNearUs"; case .DoNotAttackUs: return "MilitaryPresenceNearBorderOrAttackedUsDespitePromise" } }
    var willIgnoreViolation: String { switch self { case .DontSpyOnUs: return "IgnoreThemSendingSpies"; case .DoNotSpreadReligion: return "IgnoreThemSpreadingReligion"; case .DoNotSettleNearUs: return "IgnoreThemSettlingNearUs"; case .DoNotAttackUs: return "IgnoreMilitaryPresenceNearBorder" } }
    var refusedModifier: DiploModifier { switch self { case .DontSpyOnUs: return .RefusedToNotSendingSpiesToUs; case .DoNotSpreadReligion: return .RefusedToNotSpreadReligionToUs; case .DoNotSettleNearUs: return .RefusedToNotSettleCitiesNearUs; case .DoNotAttackUs: return .RefusedToPromiseNotToAttackUs } }
    var betrayedModifier: DiploModifier { switch self { case .DontSpyOnUs: return .BetrayedPromiseToNotSendingSpiesToUs; case .DoNotSpreadReligion: return .BetrayedPromiseToNotSpreadReligionToUs; case .DoNotSettleNearUs: return .BetrayedPromiseToNotSettleCitiesNearUs; case .DoNotAttackUs: return .BetrayedPromiseToNotAttackUs } }
    var fulfilledModifier: DiploModifier { switch self { case .DontSpyOnUs: return .FulfilledPromiseToNotSpy; case .DoNotSpreadReligion: return .FulfilledPromiseToNotSpreadReligion; case .DoNotSettleNearUs: return .FulfilledPromiseToNotSettleCitiesNearUs; case .DoNotAttackUs: return .FulfilledPromiseToNotAttackUs } }
    var acceptDemandText: String { switch self { case .DontSpyOnUs: return "We see our people are not welcome in your lands... we will take our attention elsewhere."; case .DoNotSpreadReligion: return "Very well, we shall spread our faith elsewhere."; case .DoNotSettleNearUs: return "Very well, we shall look for new lands to settle."; case .DoNotAttackUs: return "Do not worry. Our soldiers are merely passing by." } }
    var refuseDemandText: String { switch self { case .DontSpyOnUs: return "I'll do what's necessary for my empire to survive."; case .DoNotSpreadReligion: return "We shall do as we please."; case .DoNotSettleNearUs: return "We shall do as we please."; case .DoNotAttackUs: return "Our military stands ready to finish what diplomacy could not! (DECLARE WAR)" } }
    var wePromisedText: String { switch self { case .DontSpyOnUs: return "We promised not to send spies to them ([turns] turns remaining)"; case .DoNotSpreadReligion: return "We promised not to spread religion to them ([turns] turns remaining)"; case .DoNotSettleNearUs: return "We promised not to settle near them ([turns] turns remaining)"; case .DoNotAttackUs: return "We promised not to attack them ([turns] turns remaining)" } }
    var theyPromisedText: String { switch self { case .DontSpyOnUs: return "They promised not to send spies to us ([turns] turns remaining)"; case .DoNotSpreadReligion: return "They promised not to spread religion to us ([turns] turns remaining)"; case .DoNotSettleNearUs: return "They promised not to settle near us ([turns] turns remaining)"; case .DoNotAttackUs: return "They promised not to attack us ([turns] turns remaining)" } }
    var demandText: String { switch self { case .DontSpyOnUs: return "Stop spying on us."; case .DoNotSpreadReligion: return "Please don't spread your religion to us."; case .DoNotSettleNearUs: return "Please don't settle new cities near us."; case .DoNotAttackUs: return "We have noticed substantial military activity near our borders. How should we interpret this?" } }
    var agreedText: String { switch self { case .DontSpyOnUs: return "[civName] agreed to stop spying on us!"; case .DoNotSpreadReligion: return "[civName] agreed to stop spreading religion to us!"; case .DoNotSettleNearUs: return "[civName] agreed to stop settling cities near us!"; case .DoNotAttackUs: return "[civName] has promised not to attack us!" } }
    var refusedText: String { switch self { case .DontSpyOnUs: return "[civName] refused to stop spying on us!"; case .DoNotSpreadReligion: return "[civName] refused to stop spreading religion to us!"; case .DoNotSettleNearUs: return "[civName] refused to stop settling cities near us!"; case .DoNotAttackUs: return "[civName] declared war on us after we questioned the positioning of their military!" } }
    var violationNoticedText: String { switch self { case .DontSpyOnUs: return "Take back your spy and your broken promises."; case .DoNotSpreadReligion: return "We noticed you have continued spreading your religion to us, despite your promise. This will have....consequences."; case .DoNotSettleNearUs: return "We noticed your new city near our borders, despite your promise. This will have....implications."; case .DoNotAttackUs: return "You have exposed yourself as a treacherous warmonger." } }
}

/// A demand an AI has put to a human, waiting for the answer in the UI.
struct DemandRequest: Codable, Identifiable, Equatable {
    var id: Int
    let from: Int
    let to: Int
    let demand: Demand
}

/// Unciv WarType – decides which opinion effects a war declaration carries.
enum WarType { case directWar, cityStateAllianceWar, defensivePactWar, joinWar, teamWar }

extension GameState {
    enum Relationship: String { case unforgivable = "Unforgivable", enemy = "Enemy", competitor = "Competitor", neutral = "Neutral", favorable = "Favorable", friend = "Friend", ally = "Ally" }

    static let SPEED_ADJUSTMENT_NORMALIZATION_FACTOR = 0.67

    static let INITIAL_OPINION_CHANGE_WHEN_DENOUNCED = -35.0

    // MARK: - modifiers (Unciv DiplomacyManager.diplomaticModifiers: HashMap<String, Float>)

    /// Unciv DiplomacyManager.opinionOfOtherCiv: `diplomaticModifiers.values.sum()` - a Float sum, walked in the
    /// HashMap's own order - less AttackedProtectedMinor when DestroyedProtectedMinor is also there.
    func opinion(of civId: Int, toward other: Int) -> Double {
        guard let c = civ(civId), let mods = c.opinions[other], !mods.isEmpty else { return 0 }
        var sum: Float = 0
        // Float addition commutes, so the order only matters from three terms on; the walk is the HashMap's - bucket by
        // bucket, each bucket in insertion order (opinionOrder)
        if mods.count <= 2 { for v in mods.values { sum += Float(v) } }
        else { for k in javaHashMapOrder(Civilization.ordered(c.opinionOrder[other] ?? [], Set(mods.keys))) { sum += Float(mods[k] ?? 0) } }
        if mods[DiploModifier.DestroyedProtectedMinor.rawValue] != nil, let a = mods[DiploModifier.AttackedProtectedMinor.rawValue] { sum -= Float(a) }
        return Double(sum)
    }

    func hasModifier(_ civId: Int, _ other: Int, _ m: DiploModifier) -> Bool { civ(civId)?.opinions[other]?[m.rawValue] != nil }

    func modifier(_ civId: Int, _ other: Int, _ m: DiploModifier) -> Double { civ(civId)?.opinions[other]?[m.rawValue] ?? 0 }

    /// Unciv addModifier - accumulates in Float (optionally clamped) and drops the entry when it reaches zero.
    /// A city-state's modifiers are never read (its relationship is its influence), so it keeps none.
    func addModifier(_ civId: Int, _ other: Int, _ m: DiploModifier, _ amount: Double, limit: Double? = nil) {
        guard let i = civIndex(civId), civs[i].isMajor, civId != other else { return }
        var v = Float(civs[i].opinions[other]?[m.rawValue] ?? 0) + Float(amount)
        if let l = limit { v = l < 0 ? max(v, Float(l)) : min(v, Float(l)) }
        if v == 0 { civs[i].opinions[other]?[m.rawValue] = nil } else { civs[i].opinions[other, default: [:]][m.rawValue] = Double(v) }
    }

    func setModifier(_ civId: Int, _ other: Int, _ m: DiploModifier, _ amount: Double) {
        guard let i = civIndex(civId), civs[i].isMajor, civId != other else { return }
        civs[i].opinions[other, default: [:]][m.rawValue] = Double(Float(amount))
    }

    func removeModifier(_ civId: Int, _ other: Int, _ m: DiploModifier) {
        guard let i = civIndex(civId) else { return }
        civs[i].opinions[other]?[m.rawValue] = nil
    }

    func replaceModifier(_ civId: Int, _ other: Int, _ old: DiploModifier, _ new: DiploModifier, _ amount: Double) {
        removeModifier(civId, other, old); addModifier(civId, other, new, amount)
    }

    /// Legacy helpers kept for older call sites: keyed by a DiploModifier name when it matches, else ignored.
    func addOpinion(_ civId: Int, toward other: Int, _ key: String, _ amount: Double) { if let m = DiploModifier(rawValue: key) { addModifier(civId, other, m, amount) } }

    func setOpinion(_ civId: Int, toward other: Int, _ key: String, _ amount: Double) { if let m = DiploModifier(rawValue: key) { setModifier(civId, other, m, amount) } }

    // MARK: - relationship

    /// Unciv DiplomacyManager.relationshipIgnoreAfraid
    func relationshipIgnoreAfraid(_ civId: Int, _ other: Int) -> RelationshipLevel {
        guard let a = civ(civId), civ(other) != nil else { return .neutral }
        if a.isPlayer && (civ(other)?.isPlayer ?? false) { if GameState.evlogOn { hbr("A9.twoHumansNeutral", civId) }; return .neutral }   // people make their own choices
        if a.isPlayer { if GameState.evlogOn { hbr("A9.humanMirrorsOther", civId) }; return relationshipLevel(other, civId) }
        if a.isCityState {
            let inf = influence(of: other, with: civId)   // getInfluence tests isAtWarWith
            if inf <= -30 { return .unforgivable }
            if inf < 0 { return .enemy }
            if inf >= 60 && ally(of: civId) == other { return .ally }
            if inf >= 30 { return .friend }
            return .neutral
        }
        let o = opinion(of: civId, toward: other)
        if o <= -80 { return .unforgivable }
        if o <= -40 || a.isAtWar(with: other) { return .enemy }   // during wartime, enemy OR unforgivable
        if o <= -15 { return .competitor }
        if o >= 80 { return .ally }
        if o >= 40 { return .friend }
        if o >= 15 { return .favorable }
        return .neutral
    }

    /// Unciv DiplomacyManager.relationshipLevel: a city-state that would be Neutral is Afraid when it would pay tribute.
    func relationshipLevel(_ civId: Int, _ other: Int) -> RelationshipLevel {
        let level = relationshipIgnoreAfraid(civId, other)
        guard level == .neutral, civ(civId)?.isCityState == true else { return level }
        return tributeWillingness(from: other, civId) > 0 ? .afraid : .neutral   // Unciv: strictly above zero
    }

    func relationship(_ civId: Int, _ other: Int) -> Relationship {
        switch relationshipLevel(civId, other) {
        case .unforgivable: return .unforgivable
        case .enemy: return .enemy
        case .competitor: return .competitor
        case .afraid, .neutral: return .neutral
        case .favorable: return .favorable
        case .friend: return .friend
        case .ally: return .ally
        }
    }

    /// Unciv DiplomacyManager.getCommonKnownCivs: `civInfo.getKnownCivs().intersect(otherCiv.getKnownCivs())` - a
    /// set that keeps OUR diplomacy map's order (ours sorted by id). The WithSpectators variant keeps the spectator.
    func commonKnownCivIds(_ a: Int, _ b: Int, withSpectators: Bool = false) -> [Int] {
        guard let cb = civ(b) else { return [] }
        return knownCivs(a).filter { $0.id != a && $0.id != b && cb.metCivs.contains($0.id) && (withSpectators || !$0.isSpectator) }.map { $0.id }
    }

    private func believesSameReligion(_ civId: Int, _ other: Int) -> Bool {
        // Unciv: our majority religion (most followed across our cities) is also the other's majority religion.
        func majority(_ id: Int) -> String? {
            var counts: [String: Int] = [:]
            for c in cities(of: id) { if let r = majorityReligion(of: c) { counts[r, default: 0] += 1 } }
            guard let best = counts.max(by: { $0.value < $1.value }), best.value > cities(of: id).count / 2 else { return nil }
            return best.key
        }
        guard let ours = majority(civId) else { return false }
        return majority(other) == ours
    }

    /// Unciv DiplomacyScreen.getHumanRelationshipText: between two humans only the standing is named.
    func humanRelationshipText(_ other: Int, _ me: Int) -> String {
        if civ(other)?.defensivePacts.contains(me) == true { return "Defensive Pact" }
        if hasFlag(other, me, "DeclarationOfFriendship") { return "Friend" }
        if areAtWar(other, me) { return "Enemy" }
        return "Neutral"
    }

    // MARK: - friendship- and pact-based modifiers

    /// Unciv setFriendshipBasedModifier: how `civId` feels about `other` declaring friendship with third parties.
    func setFriendshipBasedModifier(_ civId: Int, _ other: Int) {
        removeModifier(civId, other, .DeclaredFriendshipWithOurAllies); removeModifier(civId, other, .DeclaredFriendshipWithOurEnemies)
        for third in commonKnownCivIds(civId, other) where hasFlag(third, other, "DeclarationOfFriendship") {
            let rel = relationshipIgnoreAfraid(civId, third)
            let type: DiploModifier = (rel == .unforgivable || rel == .enemy) ? .DeclaredFriendshipWithOurEnemies : .DeclaredFriendshipWithOurAllies
            let value: Double = rel == .unforgivable ? -15 : rel == .enemy ? -5 : rel == .friend ? 5 : rel == .ally ? 15 : 0
            addModifier(civId, other, type, value)
        }
    }

    /// Unciv setDefensivePactBasedModifier
    func setDefensivePactBasedModifier(_ civId: Int, _ other: Int) {
        removeModifier(civId, other, .SignedDefensivePactWithOurAllies); removeModifier(civId, other, .SignedDefensivePactWithOurEnemies)
        for third in commonKnownCivIds(civId, other) where hasFlag(other, third, "DefensivePact") {
            let rel = relationshipIgnoreAfraid(civId, third)
            let type: DiploModifier = (rel == .unforgivable || rel == .enemy) ? .SignedDefensivePactWithOurEnemies : .SignedDefensivePactWithOurAllies
            let value: Double = rel == .unforgivable ? -15 : rel == .enemy ? -10 : rel == .friend ? 2 : rel == .ally ? 5 : 0
            addModifier(civId, other, type, value)
        }
    }

    /// Unciv setReligionBasedModifier
    func setReligionBasedModifier(_ civId: Int, _ other: Int) {
        if believesSameReligion(other, civId) { setModifier(civId, other, .BelieveSameReligion, 5) } else { removeModifier(civId, other, .BelieveSameReligion) }
    }

    // MARK: - denounce

    func canDenounce(_ a: Int, _ b: Int) -> Bool {
        guard let ca = civ(a), let cb = civ(b), ca.isMajor, cb.isMajor, !ca.isAtWar(with: b) else { return false }
        return !hasFlag(a, b, "Denunciation") && !hasFlag(a, b, "DeclarationOfFriendship")
    }

    /// Unciv DiplomacyManager.denounce / activateDenounceEffects
    func denounce(_ a: Int, _ b: Int) {
        guard canDenounce(a, b), let ai = civIndex(a), let bi = civIndex(b) else { return }
        civs[ai].denouncements[b] = turn
        // -35, -25, -18, -12, ...: the more civs already denounce them, the less ours surprises them (Float)
        let active = knownCivs(b).filter { hasFlag($0.id, b, "Denunciation") }.count
        let change = Float(GameState.INITIAL_OPINION_CHANGE_WHEN_DENOUNCED) * powf(2, -0.5 * Float(active))
        setModifier(b, a, .Denunciation, Double(change))
        setFlag(a, b, "Denunciation", 30)
        addAlert(b, .Denounced, "\(a)")
        notify(b, "[\(civs[ai].nation)] has denounced us!", category: .Diplomacy, icons: ["Diplomacy", civs[ai].nation])
        removeEmbassies(a, b)
        for third in commonKnownCivIds(a, b, withSpectators: true) {
            notify(third, "[\(civs[ai].nation)] has denounced [\(civs[bi].nation)]!", category: .Diplomacy, icons: [civs[ai].nation, "Diplomacy", civs[bi].nation])
            if civ(third)?.isSpectator == true { continue }
            switch relationshipIgnoreAfraid(third, b) {
            case .unforgivable: addModifier(third, a, .DenouncedOurEnemies, 15)
            case .enemy: addModifier(third, a, .DenouncedOurEnemies, 5)
            case .friend: addModifier(third, a, .DenouncedOurAllies, -5)
            case .ally: addModifier(third, a, .DenouncedOurAllies, -15)
            default: break
            }
        }
    }

    // MARK: - defensive pact

    /// Unciv DiplomacyFunctions.canSignDefensivePactWith
    func canSignDefensivePact(_ a: Int, _ b: Int) -> Bool {
        guard let ca = civ(a), let cb = civ(b), ca.isMajor, cb.isMajor, !ca.isAtWar(with: b), !ca.defensivePacts.contains(b), advancedDiplomacyAllowed(a, b) else { return false }
        func enabled(_ c: Civilization) -> Bool { c.techs.contains { rs.techs[$0]?.uniques.contains(where: { $0.hasPrefix("Enables Defensive Pacts") }) == true } }
        return enabled(ca) && enabled(cb) && hasFlag(a, b, "DeclarationOfFriendship") && !hasFlag(a, b, "DefensivePact") && !hasFlag(b, a, "DefensivePact")
    }
}
