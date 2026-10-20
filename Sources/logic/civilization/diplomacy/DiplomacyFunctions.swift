// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/civilization/diplomacy/DiplomacyFunctions.kt` (embassies, friendship, defensive pacts and
/// what a civ is allowed to do diplomatically) and of DiplomacyManager.signDeclarationOfFriendship / signDefensivePact.
extension GameState {
    /// Unciv keeps no embassy list: `civId` has an embassy in `other`'s capital exactly when its manager with `other`
    /// carries EstablishedEmbassy or SharedEmbassies (canEstablishEmbassyWith / canOfferEmbassyTo test those).
    /// Ours kept a separate set that an imported game never filled, so embassies Unciv had were offered again.
    func hasEmbassy(_ civId: Int, with other: Int) -> Bool { hasModifier(civId, other, .EstablishedEmbassy) || hasModifier(civId, other, .SharedEmbassies) }

    /// Unciv isDenouncedThisTurn: a denunciation from either side this turn blocks embassies until the next.
    private func denouncedThisTurn(_ a: Int, _ b: Int) -> Bool { flag(a, b, "Denunciation") == 30 || flag(b, a, "Denunciation") == 30 }

    /// Unciv DiplomacyFunctions.canEstablishEmbassyWith: `civId` establishes an embassy in `other`'s capital.
    func canEstablishEmbassy(_ civId: Int, with other: Int) -> Bool {
        guard canTradeEmbassies(civId), civ(other)?.isMajor == true, capital(of: other) != nil else { return false }
        return !areAtWar(civId, other) && !denouncedThisTurn(civId, other) && !hasEmbassy(civId, with: other)
    }

    /// Unciv DiplomacyFunctions.canOfferEmbassyTo: we let `other` place an embassy in our capital.
    func canOfferEmbassy(_ civId: Int, to other: Int) -> Bool {
        guard canTradeEmbassies(civId), civ(other)?.isMajor == true, capital(of: civId) != nil else { return false }
        return !areAtWar(civId, other) && !denouncedThisTurn(other, civId) && !hasEmbassy(other, with: civId)
    }

    /// Unciv DiplomacyFunctions.canTradeEmbassies: a major civ with the EnablesEmbassies unique.
    func canTradeEmbassies(_ civId: Int) -> Bool {
        guard let a = civ(civId), a.isMajor else { return false }
        return a.techs.contains { rs.techs[$0]?.uniques.contains(where: { $0.hasPrefix("Enables establishment of embassies") || $0.hasPrefix("Enables embassies") }) == true }
    }

    var embassyCost: Double { 30 * speed.goldCostModifier }

    /// Unciv TradeLogic.acceptTrade applyEmbassyOffer, for `giver`'s manager with `receiver` (the giver lets the
    /// receiver put an embassy in its capital).
    func applyEmbassyModifiers(_ receiver: Int, with giver: Int) {
        if hasModifier(giver, receiver, .EstablishedEmbassy) {
            replaceModifier(giver, receiver, .EstablishedEmbassy, .SharedEmbassies, 3)
            replaceModifier(receiver, giver, .ReceivedEmbassy, .SharedEmbassies, 3)
        } else {
            addModifier(giver, receiver, .ReceivedEmbassy, 1)
            addModifier(receiver, giver, .EstablishedEmbassy, 2)
        }
    }

    @discardableResult
    func establishEmbassy(_ civId: Int, with other: Int) -> Bool {
        guard canEstablishEmbassy(civId, with: other), let i = civIndex(civId), civs[i].gold >= embassyCost else { return false }
        civs[i].gold -= embassyCost
        civs[i].embassiesWith.insert(other)
        civs[i].explored.formUnion(cities(of: other).filter { $0.isCapital }.flatMap { map.tilesWithin($0.coord, radius: 2) })
        // as TradeLogic's Embassy transfer: `forEachTileInDistance(2) { it.setExplored(to, true) }`, ring by ring
        if let capital = cities(of: other).first(where: { $0.isCapital }) { checkExploredRegion(i, map.tilesInDistanceUncivOrder(capital.coord, radius: 2), explorer: nil) }
        applyEmbassyModifiers(civId, with: other)
        return true
    }

    /// Unciv DiplomacyFunctions.removeEmbassies
    func removeEmbassies(_ a: Int, _ b: Int) {
        if let ai = civIndex(a) { civs[ai].embassiesWith.remove(b) }
        if let bi = civIndex(b) { civs[bi].embassiesWith.remove(a) }
        for m in [DiploModifier.EstablishedEmbassy, .ReceivedEmbassy, .SharedEmbassies] { removeModifier(a, b, m) }
        for m in [DiploModifier.EstablishedEmbassy, .ReceivedEmbassy, .SharedEmbassies] { removeModifier(b, a, m) }
    }

    /// Unciv DiplomacyFunctions.meetsEmbassyRequirementFor, for `a` (civInfo) with `b`: without the
    /// RequiresEmbassiesForDiplomacy unique anything goes, with it `a`'s manager must carry SharedEmbassies.
    /// Ours also accepted two one-way embassies, which Unciv does not.
    func advancedDiplomacyAllowed(_ a: Int, _ b: Int) -> Bool {
        let requires = rs.globalUniques.contains { $0.pattern == "Requires establishing embassies to conduct advanced diplomacy" }
        return !requires || hasModifier(a, b, .SharedEmbassies)
    }

    // MARK: - friendship

    /// Unciv DiplomacyFunctions.canSignDeclarationOfFriendshipWith: `b` is a major civ not at war with `a`, and
    /// `a` has neither denounced nor already befriended `b`.
    func canDeclareFriendship(_ a: Int, _ b: Int) -> Bool {
        if rs.modOptionUniques.contains(where: { $0.pattern == "Diplomatic relationships cannot change" }) { return false }   // Unciv DiplomaticRelationshipsCannotChange
        guard civ(a)?.isMajor == true, let cb = civ(b), cb.isMajor, !cb.isAtWar(with: a) else { return false }
        return !hasFlag(a, b, "Denunciation") && !hasFlag(a, b, "DeclarationOfFriendship")
    }

    /// Unciv DiplomacyManager.signDeclarationOfFriendship, `a` being the manager's civ. Unciv tells the two
    /// signatories nothing here (the requester is told by respondToDeclarationOfFriendship). Like Unciv it asks
    /// nothing either: the AI's answers and the trade check canDeclareFriendship first, and a player accepting the
    /// popup signs even with their own Denunciation of the offerer still running.
    func declareFriendship(_ a: Int, _ b: Int) {
        guard let ai = civIndex(a), let bi = civIndex(b) else { return }
        setModifier(a, b, .DeclarationOfFriendship, 35); setModifier(b, a, .DeclarationOfFriendship, 35)
        setFlag(a, b, "DeclarationOfFriendship", 30); setFlag(b, a, "DeclarationOfFriendship", 30)
        civs[ai].friendships[b] = turn; civs[bi].friendships[a] = turn
        for third in commonKnownCivIds(a, b, withSpectators: true) {
            notify(third, "[\(civs[ai].nation)] and [\(civs[bi].nation)] have signed a Declaration of Friendship!", category: .Diplomacy, icons: [civs[ai].nation, "Diplomacy", civs[bi].nation])
            if civ(third)?.isSpectator == true { continue }
            setFriendshipBasedModifier(third, a); setFriendshipBasedModifier(third, b)
        }
        // Unciv DiplomacyManager.signDeclarationOfFriendship: TriggerUponDeclaringFriendship on both sides
        triggerConditionalUniques(civId: a) { $0.pattern == "upon declaring friendship" }
        triggerConditionalUniques(civId: b) { $0.pattern == "upon declaring friendship" }
    }

    /// Unciv DiplomacyManager.signDefensivePact(duration), `a` being the manager's civ: both sides' modifier, flag
    /// and status. The onlookers re-score only `a` - and Unciv's loop `return`s (not `continue`s) at a spectator,
    /// so the onlookers after it in `a`'s diplomacy order, and the triggers, are skipped.
    func signDefensivePact(_ a: Int, _ b: Int, duration: Int? = nil) {
        guard let ai = civIndex(a), let bi = civIndex(b) else { return }
        let d = duration ?? speed.dealDuration
        setModifier(a, b, .DefensivePact, 10); setModifier(b, a, .DefensivePact, 10)
        setFlag(a, b, "DefensivePact", d); setFlag(b, a, "DefensivePact", d)
        civs[ai].defensivePacts.insert(b); civs[bi].defensivePacts.insert(a)
        for third in commonKnownCivIds(a, b, withSpectators: true) {
            notify(third, "[\(civs[ai].nation)] and [\(civs[bi].nation)] have signed a Defensive Pact!", category: .Diplomacy, icons: [civs[ai].nation, "Diplomacy", civs[bi].nation])
            if civ(third)?.isSpectator == true { return }
            setDefensivePactBasedModifier(third, a)
        }
        triggerConditionalUniques(civId: a) { $0.pattern == "upon declaring a defensive pact" }   // Unciv TriggerUponSigningDefensivePact
        triggerConditionalUniques(civId: b) { $0.pattern == "upon declaring a defensive pact" }
    }

    /// Both sides' pact and flag gone at once - only for callers outside Unciv's per-side paths.
    func endDefensivePact(_ a: Int, _ b: Int) {
        if let ai = civIndex(a) { civs[ai].defensivePacts.remove(b) }
        if let bi = civIndex(b) { civs[bi].defensivePacts.remove(a) }
        removeFlag(a, b, "DefensivePact"); removeFlag(b, a, "DefensivePact")
    }
}
