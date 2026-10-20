// Vox Populi 4.22 World Congress for the VPiOS engine (MPL-2.0).
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// CvGameLeagues / CvLeague / CvLeagueAI, carried over in a reduced form:
// - Founded when a major civ that knows Printing Press has met every other living major civ; it hosts first.
// - Congress eras (BNW's special sessions): Renaissance, Industrial (half the civs Industrial or one Modern), Modern
//   (half Modern or one Atomic), United Nations (half Atomic or one Information). Delegates per era: civ 1/2/3/4,
//   host +1/+1/+2/+2, per allied City-State 0/1/1/2. VP's session intervals: 20 / 15 / 10 / 10 turns. A new Congress
//   era elects a host: the civ with the most delegates (the current host keeps ties).
// - Extra delegates: buildings (SingleLeagueVotes, ExtraLeagueVotes), policies (FreeWCVotes), the founder belief
//   (ExtraVotes), traits (VotePerXCSAlliance), the World Religion and World Ideology, permanent extra delegates.
// - Each session the host and the two members with the most delegates (LEAGUE_PROPOSERS_PER_SESSION 3) propose an
//   enactment or a repeal; at the next session every member spends its delegates across the proposals, and a
//   proposal passes with more Yea than Nay.
// - Resolutions: VP's texts and numbers (Database Changes/WorldCongress, Text/en_US/WorldCongress). The AI scores a
//   proposal for itself the way CvLeagueAI::ScoreVoteChoiceYesNo weighs it, in a much shorter form.
// Not carried over (GAPS.md): international projects, Global Hegemony (Unciv's own UN vote stays), sanctions,
// tourism and trade-route resolutions, vote trading, relation changes from votes.

import Foundation

enum VPResolution: String, Codable, CaseIterable {
    case banLuxury, artsFunding, sciencesFunding, peaceAccords, casusBelli, culturalHeritage, naturalHeritage,
         historicalLandmarks, techDiscount, worldReligion, worldIdeology, sphereOfInfluence, openDoor, decolonization,
         cityStateSanctions

    enum Choice { case none, luxury, religion, ideology, cityState }

    var choice: Choice {
        switch self {
        case .banLuxury: return .luxury
        case .worldReligion: return .religion
        case .worldIdeology: return .ideology
        case .sphereOfInfluence, .openDoor: return .cityState
        default: return .none
        }
    }

    var title: String {
        switch self {
        case .banLuxury: return "Ban Luxury"
        case .artsFunding: return "Endowment for the Arts"
        case .sciencesFunding: return "World Science Initiative"
        case .peaceAccords: return "Global Peace Accords"
        case .casusBelli: return "Casus Belli"
        case .culturalHeritage: return "Cultural Heritage Sites"
        case .naturalHeritage: return "Natural Heritage Sites"
        case .historicalLandmarks: return "Historical Landmarks"
        case .techDiscount: return "Scholars in Residence"
        case .worldReligion: return "World Religion"
        case .worldIdeology: return "World Ideology"
        case .sphereOfInfluence: return "Sphere of Influence"
        case .openDoor: return "Open Door"
        case .decolonization: return "Decolonization"
        case .cityStateSanctions: return "City-State Sanctions"
        }
    }

    var help: String {
        switch self {
        case .banLuxury: return "Civilizations receive no Happiness or Monopoly benefits from this Luxury resource."
        case .artsFunding: return "+33% generation of Great Writers, Artists and Musicians, -33% of Great Scientists, Engineers and Merchants. Civilizations with fewer Policies than the median get up to +30% Production and Culture."
        case .sciencesFunding: return "+33% generation of Great Scientists, Engineers and Merchants, -33% of Great Writers, Artists and Musicians. Civilizations with fewer Technologies than the median get up to +30% Food and Science."
        case .peaceAccords: return "Unit maintenance costs are raised by 25% Gold."
        case .casusBelli: return "Unit maintenance costs are lowered by 15% Gold."
        case .culturalHeritage: return "Each World Wonder provides +2 Culture to its city."
        case .naturalHeritage: return "Each Natural Wonder provides +2 to all yields when worked."
        case .historicalLandmarks: return "Great Person tile improvements provide +1 Food, Production and Gold, Landmarks +1 Science, Culture and Faith when worked."
        case .techDiscount: return "-20% research cost for Technologies already discovered by another Civilization, -2% more for every City-State ally, up to -50%."
        case .worldReligion: return "Civilizations whose cities mostly follow the religion get +1 Delegate; its founder +1 per such Civilization. The religion spreads 25% faster."
        case .worldIdeology: return "Civilizations following the Ideology get +1 Delegate, plus 1 for every other Civilization following it."
        case .sphereOfInfluence: return "The proposer, who must be its current ally, becomes the permanent Ally of the City-State."
        case .openDoor: return "Influence with the City-State is set to 40 for everyone, and no one can become its Ally."
        case .decolonization: return "Influence of all players with all City-States is lowered to 50, unless they are permanent allies."
        case .cityStateSanctions: return "All Corporation Franchises are removed from City-States, and none can be opened there."
        }
    }

    /// TechPrereqAnyMember (VP values; nil: none)
    var prereqTech: String? {
        switch self {
        case .historicalLandmarks: return "Archaeology"
        case .worldIdeology: return "Nuclear Fission"
        case .sphereOfInfluence: return "Steam Power"
        case .openDoor: return "Economics"
        case .decolonization: return "Radio"
        default: return nil
        }
    }

    /// Resolutions that cannot be active together (one each, whatever the choice).
    var exclusiveGroup: String? {
        switch self {
        case .artsFunding, .sciencesFunding: return "funding"
        case .peaceAccords, .casusBelli: return "war"
        case .worldReligion: return "religion"
        case .worldIdeology: return "ideology"
        default: return nil
        }
    }
}

struct VPLeagueEntry: Codable, Equatable {
    var resolution: VPResolution
    var choice: String?
    var proposer: Int
    var repeal: Bool = false
    var turn: Int = 0
}

struct VPLeagueState: Codable, Equatable {
    var founded = false
    var host: Int? = nil
    var era = 0
    var nextSession = 0
    var active: [VPLeagueEntry] = []
    var proposals: [VPLeagueEntry] = []
    /// the human player's delegates on each proposal (+ Yea, - Nay), by proposal index
    var playerVotes: [Int] = []
    /// the civs that may still make a proposal for the coming session (the human player picks in the Congress screen)
    var pendingProposers: [Int] = []
    var extraDelegates: [String: Int] = [:]
    var lastResults: [String] = []
}

extension GameState {
    static let vpLeagueCivDelegates = [1, 2, 3, 4], vpLeagueHostDelegates = [1, 1, 2, 2], vpLeagueCSDelegates = [0, 1, 1, 2]
    static let vpLeagueIntervals = [20, 15, 10, 10]
    static let vpLeagueEraNames = ["Renaissance", "Industrial", "Modern", "United Nations"]
    static let vpLeagueIdeologies = ["Freedom", "Order", "Autocracy"]

    var vpLeagueEnabled: Bool { vpData != nil }

    func vpLeagueMembers() -> [Civilization] { civs.filter { $0.isMajor && $0.isAlive && !cities(of: $0.id).isEmpty } }
    func vpLeagueCityStates() -> [Civilization] { civs.filter { $0.isCityState && $0.isAlive && !cities(of: $0.id).isEmpty } }

    func vpIdeology(_ civId: Int) -> String? {
        guard let c = civ(civId) else { return nil }
        return GameState.vpLeagueIdeologies.first { c.policies.contains($0) }
    }

    func vpActive(_ r: VPResolution) -> [VPLeagueEntry] { vpLeague.active.filter { $0.resolution == r } }
    func vpIsActive(_ r: VPResolution) -> Bool { vpLeague.founded && vpLeague.active.contains { $0.resolution == r } }

    // MARK: delegates

    /// (total, rows) - CvLeague::CalculateStartingVotesForMember
    func vpDelegates(_ civId: Int) -> (Int, [(String, Int)]) {
        guard vpLeague.founded, let civ = civ(civId), civ.isMajor else { return (0, []) }
        let e = min(3, max(0, vpLeague.era))
        var rows: [(String, Int)] = [("Member", GameState.vpLeagueCivDelegates[e])]
        if vpLeague.host == civId { rows.append(("Host", GameState.vpLeagueHostDelegates[e])) }
        let allies = vpLeagueCityStates().filter { isAlly(civId, of: $0.id) }.count
        if allies > 0, GameState.vpLeagueCSDelegates[e] > 0 { rows.append(("City-State allies", allies * GameState.vpLeagueCSDelegates[e])) }
        if let d = vpData {
            let b = cities(of: civId).flatMap { $0.buildings }.reduce(0) { $0 + Int(VPData.column(d.buildings[$1], "SingleLeagueVotes") + VPData.column(d.buildings[$1], "ExtraLeagueVotes")) }
            if b > 0 { rows.append(("Buildings", b)) }
            let p = civ.policies.reduce(0) { $0 + Int(VPData.column(d.policies[$1], "FreeWCVotes")) }
            if p > 0 { rows.append(("Policies", p)) }
            let r = vpCivBeliefs(civId).reduce(0) { $0 + Int(VPData.column(d.beliefs[$1], "ExtraVotes")) }
            if r > 0 { rows.append(("Religion", r)) }
            let per = Int(VPData.column(d.nations[civ.nation], "VotePerXCSAlliance"))
            if per > 0, allies / per > 0 { rows.append(("Civilization ability", allies / per)) }
        }
        if let wr = vpActive(.worldReligion).first?.choice {
            var n = 0
            if vpCivFollows(civId, religion: wr) { n += 1 }
            if religionOwner(wr)?.id == civId { n += vpLeagueMembers().filter { $0.id != civId && vpCivFollows($0.id, religion: wr) }.count }
            if n > 0 { rows.append(("World Religion", n)) }
        }
        if let wi = vpActive(.worldIdeology).first?.choice, vpIdeology(civId) == wi {
            rows.append(("World Ideology", 1 + vpLeagueMembers().filter { $0.id != civId && vpIdeology($0.id) == wi }.count))
        }
        if let x = vpLeague.extraDelegates[String(civId)], x > 0 { rows.append(("Permanent", x)) }
        return (rows.reduce(0) { $0 + $1.1 }, rows)
    }

    /// A majority of the civ's cities follow the religion.
    func vpCivFollows(_ civId: Int, religion: String) -> Bool {
        let cs = cities(of: civId)
        guard !cs.isEmpty else { return false }
        return cs.filter { majorityReligion(of: $0) == religion }.count * 2 > cs.count
    }

    // MARK: proposals

    func vpChoices(_ r: VPResolution, proposer: Int) -> [String?] {
        switch r.choice {
        case .none: return [nil]
        case .luxury:
            let present = Set(map.tiles.compactMap { $0.resource }.filter { rs.resources[$0]?.resourceType == "Luxury" })
            return present.sorted().map { Optional($0) }
        case .religion: return foundedReligions.sorted().map { Optional($0) }
        case .ideology: return GameState.vpLeagueIdeologies.filter { i in vpLeagueMembers().contains { vpIdeology($0.id) == i } }.map { Optional($0) }
        case .cityState:
            let cs = vpLeagueCityStates()
            return (r == .sphereOfInfluence ? cs.filter { isAlly(proposer, of: $0.id) } : cs).map { Optional(String($0.id)) }
        }
    }

    func vpCanPropose(_ e: VPLeagueEntry) -> Bool {
        if vpLeague.proposals.contains(where: { $0.resolution == e.resolution && $0.choice == e.choice }) { return false }
        if e.repeal { return vpLeague.active.contains { $0.resolution == e.resolution && $0.choice == e.choice } }
        if let t = e.resolution.prereqTech, rs.techs[t] != nil, !vpLeagueMembers().contains(where: { $0.techs.contains(t) }) { return false }
        if vpLeague.active.contains(where: { $0.resolution == e.resolution && $0.choice == e.choice }) { return false }
        if let g = e.resolution.exclusiveGroup, vpLeague.active.contains(where: { $0.resolution.exclusiveGroup == g }) { return false }
        if let g = e.resolution.exclusiveGroup, vpLeague.proposals.contains(where: { !$0.repeal && $0.resolution.exclusiveGroup == g }) { return false }
        if e.resolution == .sphereOfInfluence || e.resolution == .openDoor,
           vpLeague.active.contains(where: { ($0.resolution == .sphereOfInfluence || $0.resolution == .openDoor) && $0.choice == e.choice }) { return false }
        return true
    }

    /// Every enactment or repeal the civ could propose now.
    func vpProposalOptions(_ civId: Int) -> [VPLeagueEntry] {
        var out: [VPLeagueEntry] = []
        for r in VPResolution.allCases {
            if r == .worldReligion && !religionEnabled { continue }
            for c in vpChoices(r, proposer: civId) {
                let e = VPLeagueEntry(resolution: r, choice: c, proposer: civId)
                if vpCanPropose(e) { out.append(e) }
            }
        }
        for a in vpLeague.active {
            let e = VPLeagueEntry(resolution: a.resolution, choice: a.choice, proposer: civId, repeal: true)
            if vpCanPropose(e) { out.append(e) }
        }
        return out
    }

    func vpPropose(_ e: VPLeagueEntry) {
        guard vpLeague.pendingProposers.contains(e.proposer), vpCanPropose(e) else { return }
        var x = e; x.turn = turn
        vpLeague.proposals.append(x)
        vpLeague.pendingProposers.removeAll { $0 == e.proposer }
        vpLeague.playerVotes = Array(repeating: 0, count: vpLeague.proposals.count)
    }

    func vpChoiceName(_ e: VPLeagueEntry) -> String {
        guard let c = e.choice else { return "" }
        if e.resolution.choice == .cityState, let id = Int(c) { return civ(id)?.nation ?? c }
        return c
    }

    func vpEntryTitle(_ e: VPLeagueEntry) -> String {
        let base = e.choice == nil ? e.resolution.title : "\(e.resolution.title): \(vpChoiceName(e))"
        return e.repeal ? "Repeal \(base)" : base
    }

    // MARK: AI scoring (CvLeagueAI::ScoreVoteChoiceYesNo, reduced)

    func vpScore(_ civId: Int, _ e: VPLeagueEntry) -> Double {
        let s = vpEnactScore(civId, e.resolution, e.choice)
        var v = e.repeal ? -s : s
        if e.proposer == civId { v += 40 }
        return v
    }

    private func vpMedian(_ xs: [Double]) -> Double {
        let s = xs.sorted(); guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    func vpEnactScore(_ civId: Int, _ r: VPResolution, _ choice: String?) -> Double {
        guard let me = civ(civId) else { return 0 }
        let members = vpLeagueMembers()
        func ownedCount(_ civ: Int, _ pred: (Tile) -> Bool) -> Int { map.tiles.filter { $0.ownerCivId == civ && pred($0) }.count }
        switch r {
        case .banLuxury:
            guard let lux = choice else { return 0 }
            let mine = ownedCount(civId) { $0.resource == lux }
            let others = members.filter { $0.id != civId }.map { Double(ownedCount($0.id) { $0.resource == lux }) }
            let avg = others.isEmpty ? 0 : others.reduce(0, +) / Double(others.count)
            return (avg - Double(mine)) * 15 - (mine > 0 ? 20 : 0)
        case .artsFunding, .sciencesFunding:
            let pol = members.map { Double($0.policies.count) }, tec = members.map { Double($0.techs.count) }
            let culturally = Double(me.policies.count) / max(1, vpMedian(pol)) - Double(me.techs.count) / max(1, vpMedian(tec))
            return (r == .artsFunding ? 1 : -1) * culturally * 80
        case .peaceAccords, .casusBelli:
            let atWar = isAtWarAtAll(civId)
            let units = Double(units(of: civId).count), supply = Double(max(1, unitSupply(civId)))
            let martial = (atWar ? 30 : -10) + (units / supply - 0.7) * 40
            return (r == .casusBelli ? 1 : -1) * martial
        case .culturalHeritage:
            let w = Double(cities(of: civId).flatMap { $0.buildings }.filter { rs.buildings[$0]?.isWonder == true }.count)
            let avg = members.map { m in Double(cities(of: m.id).flatMap { $0.buildings }.filter { rs.buildings[$0]?.isWonder == true }.count) }
            return (w - (avg.reduce(0, +) / Double(max(1, avg.count)))) * 8
        case .naturalHeritage:
            let n = Double(ownedCount(civId) { $0.naturalWonder != nil })
            return n * 12 - 5
        case .historicalLandmarks:
            let n = Double(ownedCount(civId) { t in t.improvement.map { $0 == "Landmark" || rs.improvements[$0]?.isGreatImprovement == true } ?? false })
            return n * 6 - 5
        case .techDiscount:
            let best = Double(members.map { $0.techs.count }.max() ?? 0)
            return (best - Double(me.techs.count)) * 4 - 5
        case .worldReligion:
            guard let rel = choice else { return 0 }
            if religionOwner(rel)?.id == civId { return 80 }
            if vpCivFollows(civId, religion: rel) { return 30 }
            return me.religionName != nil ? -40 : -10
        case .worldIdeology:
            guard let i = choice else { return 0 }
            if vpIdeology(civId) == i { return 60 }
            return vpIdeology(civId) == nil ? -10 : -50
        case .sphereOfInfluence:
            guard let c = choice, let cs = Int(c) else { return 0 }
            return isAlly(civId, of: cs) ? 50 : -(influence(of: civId, with: cs) / 2 + 10)
        case .openDoor:
            guard let c = choice, let cs = Int(c) else { return 0 }
            return isAlly(civId, of: cs) ? -50 : 15 - influence(of: civId, with: cs) / 4
        case .decolonization:
            let mine = Double(vpLeagueCityStates().filter { isAlly(civId, of: $0.id) }.count)
            let avg = Double(vpLeagueCityStates().count) / Double(max(1, members.count))
            return (avg - mine) * 20
        case .cityStateSanctions:
            guard let corp = vpCorporation(of: civId) else { return 5 }
            return -Double(vpLeagueCityStates().filter { c in cities(of: c.id).contains { $0.buildings.contains(corp.franchise) } }.count) * 15
        }
    }

    // MARK: turn

    func vpLeagueTargetEra() -> Int {
        let members = vpLeagueMembers()
        guard !members.isEmpty else { return vpLeague.era }
        func idx(_ c: Civilization) -> Int { rs.eras.firstIndex { $0.name == c.eraName } ?? 0 }
        func eraIndex(_ prefix: String) -> Int? { rs.eras.firstIndex { $0.name.hasPrefix(prefix) } }
        var stage = 0
        for (s, (era, next)) in [(1, ("Industrial", "Modern")), (2, ("Modern", "Atomic")), (3, ("Atomic", "Information"))] {
            guard let e = eraIndex(era) else { continue }
            let n = eraIndex(next) ?? e + 1
            if members.filter({ idx($0) >= e }).count * 2 >= members.count || members.contains(where: { idx($0) >= n }) { stage = s }
        }
        return max(vpLeague.era, stage)
    }

    func vpLeagueTurnsToSession() -> Int { max(0, vpLeague.nextSession - turn) }

    /// Once a round (TurnManager, before the turn number advances).
    func vpLeagueTurn() {
        guard vpLeagueEnabled else { return }
        let members = vpLeagueMembers()
        if !vpLeague.founded {
            guard members.count > 1, let founder = members.first(where: { c in
                guard c.techs.contains("Printing Press") else { return false }
                let known = Set(knownCivs(c.id).map { k in k.id })
                return members.allSatisfy { m in m.id == c.id || known.contains(m.id) }
            }) else { return }
            vpLeague.founded = true
            vpLeague.host = founder.id
            vpLeague.era = vpLeagueTargetEra()
            vpLeague.nextSession = turn + GameState.vpLeagueIntervals[vpLeague.era]
            vpLeagueNotifyAll("The World Congress has been founded, hosted by [\(founder.nation)].")
            vpLeagueStartProposals()
            return
        }
        vpLeagueEnforce()
        let e = vpLeagueTargetEra()
        if e > vpLeague.era {
            vpLeague.era = e
            let best = members.max { a, b in
                let da = vpDelegates(a.id).0, db = vpDelegates(b.id).0
                return da != db ? da < db : (b.id == vpLeague.host)
            }
            if let h = best { vpLeague.host = h.id }
            vpLeagueNotifyAll("The World Congress enters the [\(GameState.vpLeagueEraNames[e])] era. [\(civ(vpLeague.host ?? -1)?.nation ?? "?")] hosts it.")
        }
        // AI proposers who have not proposed yet (a human gets until the session)
        for p in vpLeague.pendingProposers where civ(p)?.isPlayer == false { vpLeagueAIPropose(p) }
        if turn >= vpLeague.nextSession { vpLeagueSession() }
    }

    /// Self-test only: found the Congress now (the 80-turn test rarely reaches Printing Press with everyone met).
    func vpLeagueDebugFound() {
        guard vpLeagueEnabled, !vpLeague.founded, let h = vpLeagueMembers().first else { return }
        vpLeague.founded = true; vpLeague.host = h.id; vpLeague.era = vpLeagueTargetEra()
        vpLeague.nextSession = turn + GameState.vpLeagueIntervals[vpLeague.era]
        vpLeagueStartProposals()
    }

    private func vpLeagueStartProposals() {
        let members = vpLeagueMembers()
        var proposers: [Int] = []
        if let h = vpLeague.host, members.contains(where: { $0.id == h }) { proposers.append(h) }
        let others = members.filter { !proposers.contains($0.id) }.sorted { a, b in
            let da = vpDelegates(a.id).0, db = vpDelegates(b.id).0
            return da != db ? da > db : a.id < b.id
        }
        let n = Int(vpNeeds?.define("LEAGUE_PROPOSERS_PER_SESSION", 3) ?? 3)
        proposers += others.prefix(max(0, n - proposers.count)).map { $0.id }
        vpLeague.proposals = []
        vpLeague.playerVotes = []
        vpLeague.pendingProposers = proposers
        for p in proposers where civ(p)?.isPlayer == false { vpLeagueAIPropose(p) }
        for p in vpLeague.pendingProposers where civ(p)?.isPlayer == true && !epochsAutoplay {
            notify(p, "You may make a proposal to the World Congress.", category: .General, icons: ["OtherIcons/Pencil"])
        }
    }

    private func vpLeagueAIPropose(_ civId: Int) {
        let best = vpProposalOptions(civId).map { ($0, vpScore(civId, $0)) }.max { a, b in a.1 != b.1 ? a.1 < b.1 : vpEntryTitle(a.0) > vpEntryTitle(b.0) }
        if let (e, s) = best, s > 40 { vpPropose(e) } else { vpLeague.pendingProposers.removeAll { $0 == civId } }
    }

    /// Delegates on each proposal for an AI civ (signed: + Yea, - Nay), spread by how much it cares.
    func vpAIVotes(_ civId: Int) -> [Int] {
        let d = vpDelegates(civId).0
        let scores = vpLeague.proposals.map { vpScore(civId, $0) }
        let weights = scores.map { abs($0) >= 5 ? abs($0) : 0 }
        let total = weights.reduce(0, +)
        guard d > 0, total > 0 else { return scores.map { _ in 0 } }
        var votes = zip(scores, weights).map { s, w in Int((Double(d) * w / total).rounded(.down)) * (s > 0 ? 1 : -1) }
        var left = d - votes.reduce(0) { $0 + abs($1) }
        if left > 0, let top = weights.indices.max(by: { weights[$0] < weights[$1] }) {
            votes[top] += (scores[top] > 0 ? 1 : -1) * left; left = 0
        }
        return votes
    }

    private func vpLeagueSession() {
        var results: [String] = []
        var yea = Array(repeating: 0, count: vpLeague.proposals.count), nay = yea
        for m in vpLeagueMembers() {
            var v: [Int]
            if m.isPlayer && !epochsAutoplay {
                v = vpLeague.playerVotes.count == vpLeague.proposals.count ? vpLeague.playerVotes : yea.map { _ in 0 }
                let d = vpDelegates(m.id).0, used = v.reduce(0) { $0 + abs($1) }
                if used > d, used > 0 { v = v.map { $0 * d / used } }
            } else { v = vpAIVotes(m.id) }
            for (i, x) in v.enumerated() { if x > 0 { yea[i] += x } else { nay[i] -= x } }
        }
        for (i, p) in vpLeague.proposals.enumerated() {
            let passed = yea[i] > nay[i]
            results.append("\(vpEntryTitle(p)): \(passed ? "passed" : "failed") (\(yea[i]) - \(nay[i]))")
            guard passed else { continue }
            if p.repeal { vpLeague.active.removeAll { $0.resolution == p.resolution && $0.choice == p.choice } }
            else { var a = p; a.turn = turn; vpLeague.active.append(a); vpLeagueOnEnact(a) }
        }
        vpLeague.lastResults = results
        if !results.isEmpty { vpLeagueNotifyAll("World Congress session: " + results.joined(separator: "; ")) }
        vpLeague.nextSession = turn + GameState.vpLeagueIntervals[min(3, vpLeague.era)]
        vpLeagueStartProposals()
        invalidateHappiness()
    }

    private func vpLeagueOnEnact(_ a: VPLeagueEntry) {
        switch a.resolution {
        case .openDoor:
            if let c = a.choice, let cs = Int(c) { for m in vpLeagueMembers() { setInfluence(cityState: cs, major: m.id, 40) } }
        case .decolonization:
            let permanent = Set(vpActive(.sphereOfInfluence).compactMap { e in e.choice.flatMap { Int($0) }.map { "\($0)-\(e.proposer)" } })
            for cs in vpLeagueCityStates() {
                for m in vpLeagueMembers() where !permanent.contains("\(cs.id)-\(m.id)") && influence(of: m.id, with: cs.id) > 50 {
                    setInfluence(cityState: cs.id, major: m.id, 50)
                }
            }
            vpLeague.active.removeAll { $0.resolution == .decolonization }   // a one-time effect
        case .cityStateSanctions:
            if let d = vpData {
                let franchises = Set(d.corporations.map { $0.franchise })
                for cs in vpLeagueCityStates() {
                    for ci in cities.indices where cities[ci].civId == cs.id {
                        for b in cities[ci].buildings where franchises.contains(b) { removeBuilding(cityIndex: ci, b) }
                    }
                }
            }
        default: break
        }
    }

    /// Sphere of Influence and Open Door, every round.
    private func vpLeagueEnforce() {
        for e in vpActive(.sphereOfInfluence) {
            guard let c = e.choice, let cs = Int(c), civ(e.proposer)?.isAlive == true else { continue }
            let top = vpLeagueMembers().filter { $0.id != e.proposer }.map { influence(of: $0.id, with: cs) }.max() ?? 0
            let need = max(GameState.allyThreshold, top + 1)
            if influence(of: e.proposer, with: cs) < need { setInfluence(cityState: cs, major: e.proposer, need) }
        }
        for e in vpActive(.openDoor) {
            guard let c = e.choice, let cs = Int(c) else { continue }
            for m in vpLeagueMembers() where influence(of: m.id, with: cs) >= GameState.allyThreshold {
                setInfluence(cityState: cs, major: m.id, GameState.allyThreshold - 1)
            }
        }
    }

    private func vpLeagueNotifyAll(_ text: String) {
        guard !epochsAutoplay else { return }
        for m in vpLeagueMembers() where m.isPlayer { notify(m.id, text, category: .General, icons: ["OtherIcons/Pencil"]) }
    }

    // MARK: effects

    var vpBannedLuxuries: Set<String> { vpLeague.founded ? Set(vpActive(.banLuxury).compactMap { $0.choice }) : [] }

    func vpLeagueGPBonus(_ civId: Int, _ gp: String) -> Int {
        guard vpLeague.founded else { return 0 }
        let arts = ["Great Writer", "Great Artist", "Great Musician"], sci = ["Great Scientist", "Great Engineer", "Great Merchant"]
        if vpIsActive(.artsFunding) { return arts.contains(gp) ? 33 : sci.contains(gp) ? -33 : 0 }
        if vpIsActive(.sciencesFunding) { return sci.contains(gp) ? 33 : arts.contains(gp) ? -33 : 0 }
        return 0
    }

    /// Funding boosts (% in every city) for civs below the median.
    func vpLeagueCityPercent(_ city: City) -> Stats? {
        guard vpLeague.founded, let me = civ(city.civId), me.isMajor else { return nil }
        let members = vpLeagueMembers()
        func boost(_ value: (Civilization) -> Double) -> Double {
            let xs = members.map(value), best = xs.max() ?? 0
            guard best > 0, value(me) < vpMedian(xs) else { return 0 }
            return (30 * (best - value(me)) / best).rounded(.down)
        }
        var s = Stats()
        if vpIsActive(.artsFunding) { let b = boost { Double($0.policies.count) }; s.production += b; s.culture += b }
        if vpIsActive(.sciencesFunding) { let b = boost { Double($0.techs.count) }; s.food += b; s.science += b }
        return s.isEmpty ? nil : s
    }

    func vpLeagueUpkeepPercent(_ civId: Int) -> Double {
        guard vpLeague.founded else { return 0 }
        return (vpIsActive(.peaceAccords) ? 25 : 0) - (vpIsActive(.casusBelli) ? 15 : 0)
    }

    func vpLeagueCityYields(_ city: City) -> Stats? {
        guard vpIsActive(.culturalHeritage) else { return nil }
        let w = city.buildings.filter { rs.buildings[$0]?.isWonder == true }.count
        return w > 0 ? Stats(culture: Double(2 * w)) : nil
    }

    func vpLeagueTileYield(_ tile: Tile) -> Stats? {
        guard vpLeague.founded else { return nil }
        var s = Stats()
        if tile.naturalWonder != nil, vpIsActive(.naturalHeritage) {
            s = Stats(food: 2, production: 2, gold: 2, science: 2, culture: 2, faith: 2)
        }
        if let imp = tile.improvement, !tile.pillaged, vpIsActive(.historicalLandmarks) {
            if imp == "Landmark" { s.science += 1; s.culture += 1; s.faith += 1 }
            else if rs.improvements[imp]?.isGreatImprovement == true { s.food += 1; s.production += 1; s.gold += 1 }
        }
        return s.isEmpty ? nil : s
    }

    func vpLeagueTechCostFactor(_ tech: String, _ civId: Int) -> Double {
        guard vpIsActive(.techDiscount), civs.contains(where: { $0.id != civId && $0.isMajor && $0.techs.contains(tech) }) else { return 1 }
        let allies = vpLeagueCityStates().filter { isAlly(civId, of: $0.id) }.count
        return 1 - Double(min(50, 20 + 2 * allies)) / 100
    }

    func vpLeagueReligionPressure(_ religion: String) -> Double {
        vpActive(.worldReligion).contains { $0.choice == religion } ? 1.25 : 1
    }

    func vpLeagueBlocksFranchise(in city: City) -> Bool {
        vpIsActive(.cityStateSanctions) && civ(city.civId)?.isCityState == true
    }
}
