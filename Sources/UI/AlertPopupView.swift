// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv AlertPopup: presents the first queued PopupAlert of the player (first contact, war declarations, city conquered, demands…).
struct AlertPopupView: View {
    @ObservedObject var controller: GameController
    let alert: PopupAlert

    private var s: GameState { controller.state }
    private var civ: Civilization? { Int(alert.value).flatMap { s.civ($0) } }
    private var city: City? { Int(alert.value).flatMap { s.city($0) } }

    var body: some View {
        // A popup taller than the screen used to be squeezed until SwiftUI cut its paragraphs off with an
        // ellipsis - the leader's greeting lost its last line on a phone. The panel is now bounded by the screen
        // and the text scrolls inside it, rather than the panel growing past the edges and the whole thing being
        // scrolled: a popup should stay a popup. Short ones still take only the height they need.
        GeometryReader { geo in
            ZStack {
                // Unciv Popup.getBehindClickListener: a tap behind the popup runs its last close button (onCloseCallback)
                Color.black.opacity(0.55).ignoresSafeArea().bleedIntoCutout().onTapGesture { controller.alertTappedBehind(alert) }
                // Unciv Popup Scrollability.WithoutButtons: the content scrolls, the bottomTable buttons stay below it
                Panel(padding: 18, highlighted: true) {
                    VStack(spacing: 12) {
                        ViewThatFits(in: .vertical) {
                            VStack(spacing: 12) { content }.fixedSize(horizontal: false, vertical: true)
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(spacing: 12) { content }.fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        bottomButtons
                    }
                }
                .frame(maxWidth: 360)
                .frame(maxHeight: max(140, geo.size.height - 32))
                .padding(16)
            }
        }
    }

    private func close() { controller.dismissAlert(alert) }
    /// The button `option` (Unciv's button text): GameState.answerAlert runs its handler and closes the popup.
    private func answer(_ option: String) { controller.answerAlert(alert, option: option) }
    /// Unciv `nation.line.ifEmpty { default }`.
    private func nonEmpty(_ line: String?, _ fallback: String) -> String { if let line, !line.isEmpty { return line }; return fallback }

    // MARK: per-type content (Unciv AlertPopup handlers)
    @ViewBuilder private var content: some View {
        switch alert.type {
        case .StartIntro:
            leader(s.player)
            // Unciv addStartIntro: the nation's startIntroPart1 and startIntroPart2, each a label even when empty
            Text(L(s.player.nationDef?.startIntroPart1 ?? "")).font(Theme.body).multilineTextAlignment(.center)
            Text(L(s.player.nationDef?.startIntroPart2 ?? "")).font(Theme.body).multilineTextAlignment(.center)
        case .FirstContact:
            if let c = civ {
                leader(c)
                if c.isCityState {
                    // Unciv addFirstContact: "We have encountered the City-State of [${nation.name}]!"
                    Text(L("We have encountered the City-State of [\(c.nation)]!")).font(Theme.body).multilineTextAlignment(.center)
                } else {
                    // Unciv addFirstContact: addGoodSizedLabel(nation.introduction), no stand-in when the nation has none
                    Text(L(c.nationDef?.introduction ?? "")).font(Theme.body).multilineTextAlignment(.center)
                }
            }
        case .WarDeclaration:
            if let c = civ {
                leader(c)
                header(L("DECLARATION OF WAR"), color: Color(red: 1, green: 0.33, blue: 0.33))
                // Unciv addWarDeclaration: only the nation's declaringWar line, when it has one.
                if let m = c.nationDef?.declaringWar, !m.isEmpty { Text(L(m)).font(Theme.body).multilineTextAlignment(.center) }
            }
        case .Denounced:
            if let c = civ {
                leader(c)
                header(L("DENOUNCEMENT"), color: Color(red: 1, green: 0.4, blue: 0))
                Text(s.relationshipLevel(c.id, s.playerId) >= .competitor ? L(nonEmpty(c.nationDef?.neutralDenouncing, "You have violated our bond of trust. This is intolerable!")) : L(nonEmpty(c.nationDef?.hateDenouncing, "You are a scourge upon this earth. I denounce you!"))).font(Theme.body).multilineTextAlignment(.center)
            }
        case .DeclarationOfFriendship:
            if let c = civ, !s.player.isAtWar(with: c.id) {
                leader(c)
                header(L("DECLARATION OF FRIENDSHIP"), color: Color(red: 0.33, green: 1, blue: 0.33))
                Text(L(nonEmpty(c.nationDef?.declaringFriendship, "My friend, shall we declare our friendship to the world?"))).font(Theme.body).multilineTextAlignment(.center)
            }
        case .BorderConflict:
            if let c = civ {
                leader(c)
                Text(L("Remove your troops in our border immediately!")).font(Theme.body).multilineTextAlignment(.center)
            }
        case .TilesStolen:
            if let c = civ {
                leader(c)
                Text(L("Those lands were not yours to take. This has not gone unnoticed.")).font(Theme.body).multilineTextAlignment(.center)
            }
        case .DemandToStopSettlingCitiesNear, .DemandToStopSpreadingReligion, .DemandToStopSpyingOnUs, .DemandToNotAttackUs, .SpyingOnUsDespiteOurPromise:
            if let c = civ, let demand = Demand.forDemandAlert(alert.type) {
                leader(c)
                Text(L(demand.demandText)).font(Theme.body).multilineTextAlignment(.center)
            }
        case .CitySettledNearOtherCivDespiteOurPromise, .ReligionSpreadDespiteOurPromise, .AttackedUsDespitePromise:
            if let c = civ, let demand = Demand.forDemandAlert(alert.type) {
                leader(c)
                Text(L(demand.violationNoticedText)).font(Theme.body).multilineTextAlignment(.center)
            }
        case .AcceptingDemand:
            if let c = civ {
                leader(c)
                header(L("ACCEPTING DEMAND"), color: .yellow)
                Text(L(nonEmpty(c.nationDef?.acceptingDemand, "We will comply, but our consent is given grudgingly."))).font(Theme.body).multilineTextAlignment(.center)
            }
        case .RejectingDemand:
            if let c = civ {
                leader(c)
                header(L("REJECTING DEMAND"), color: Color(red: 1, green: 0.4, blue: 0))
                Text(s.relationshipLevel(c.id, s.playerId) >= .competitor ? L(nonEmpty(c.nationDef?.neutralRejectingDemand, "Your demands are in poor taste. We shall decide this matter on our own.")) : L(nonEmpty(c.nationDef?.hateRejectingDemand, "Did you really expect us to bend to such brazen demands?"))).font(Theme.body).multilineTextAlignment(.center)
            }
        case .BulliedProtectedMinor, .AttackedProtectedMinor, .AttackedAllyMinor:
            let parts = alert.value.split(separator: "@").compactMap { Int($0) }
            if parts.count == 2, let bully = s.civ(parts[0]), let cs = s.civ(parts[1]) {
                leader(bully)
                let nice = s.relationshipLevel(bully.id, s.playerId) >= .neutral
                // Unciv addBulliedOrAttackedProtectedOrAlliedMinor: "[${cityState.civName}]" filled in before tr()
                let text: String = {
                    switch alert.type {
                    case .BulliedProtectedMinor: return nice ? L("I've been informed that my armies have taken tribute from [\(cs.nation)], a city-state under your protection.\nI assure you, this was quite unintentional, and I hope that this does not serve to drive us apart.") : L("We asked [\(cs.nation)] for a tribute recently and they gave in.\nYou promised to protect them from such things, but we both know you cannot back that up.")
                    default: return nice ? L("It's come to my attention that I may have attacked [\(cs.nation)].\nWhile it was not my goal to be at odds with your empire, this was deemed a necessary course of action.") : L("I thought you might like to know that I've launched an invasion of one of your little pet states.\nThe lands of [\(cs.nation)] will make a fine addition to my own.")
                    }
                }()
                Text(text).font(Theme.body).multilineTextAlignment(.center)
            }
        case .Defeated:
            if let c = civ {
                leader(c)
                // Unciv addDefeated: addGoodSizedLabel(civInfo.nation.defeated), empty when the nation has none
                Text(L(c.nationDef?.defeated ?? "")).font(Theme.body).multilineTextAlignment(.center)
            }
        case .WonderBuilt:
            Text(L(alert.value)).font(Theme.title(20)).foregroundStyle(Theme.gold)
            Divider2()
            ArtIcon(name: alert.value, folder: "BuildingIcons", fallback: "building.columns.fill", size: 72)
            // Unciv addWonderBuilt: the quote beside wonder.getShortDescription()
            if let b = s.rs.buildings[alert.value] {
                HStack(alignment: .top, spacing: 12) {
                    if !b.quote.isEmpty { Text(L(b.quote)).font(Theme.caption).foregroundStyle(Theme.creamDim) }
                    Text(ObjectDescriptions.buildingShortUnciv(b)).font(Theme.small).foregroundStyle(Theme.cream)
                }
            }
        case .TechResearched:
            // Unciv addTechResearched: the name, then the quote, the icon and tech.getDescription(viewingCiv)
            Text(L(alert.value)).font(Theme.title(20)).foregroundStyle(Theme.gold)
            Divider2()
            HStack(alignment: .top, spacing: 12) {
                if let q = s.rs.techs[alert.value]?.quote, !q.isEmpty { Text(L(q)).font(Theme.caption).foregroundStyle(Theme.creamDim) }
                ArtIcon(name: alert.value, folder: "TechIcons", fallback: "book", size: 64)
                if let t = s.rs.techs[alert.value] { Text(ObjectDescriptions.techDescription(t, civId: s.playerId, s: s)).font(Theme.small).foregroundStyle(Theme.cream) }
            }
        case .GoldenAge:
            Text(L("GOLDEN AGE")).font(Theme.title(20)).foregroundStyle(Theme.gold)
            Divider2()
            Text(L("Your citizens have been happy with your rule for so long that the empire enters a Golden Age!")).font(Theme.body).multilineTextAlignment(.center)
        case .CityConquered:
            if let c = city {
                Text(L("What would you like to do with the city of [\(c.name)]?")).font(Theme.heading(16)).multilineTextAlignment(.center)
                let mayNotAnnex = s.mayNotAnnexCities(s.playerId)   // Unciv CityConquered popup (One City Challenge)
                // Unciv: foundingCivObject != null, `city.civ != foundingCivObject` ("can't liberate if the city actually
                // belongs to those guys" - the city is still the loser's here) and the founder is not us
                if c.originalOwner >= 0, let founder = s.civ(c.originalOwner), c.civId != founder.id, s.playerId != founder.id {
                    button(L("Liberate (city returns to [\(founder.nation)])"), key: .char("l")) { answer("Liberate") }
                    note(L("Liberating a city returns it to its original owner, giving you a massive relationship boost with them!"))
                    Divider2()
                }
                if s.isOneCityChallenger(s.playerId) {
                    button(L("Destroy"), destructive: true, key: .char("d")) { answer("Destroy") }
                    note(L("Destroying the city instantly razes the city to the ground."))
                } else {
                    // Unciv CityConquered: Annex is disabled (not hidden) when the civilization may not annex cities
                    button(L("Annex"), enabled: !mayNotAnnex, key: .char("a")) { answer("Annex") }
                    if mayNotAnnex { note(L("Your civilization may not annex this city.")) }
                    else { note(L("Annexed cities become part of your regular empire.")); note(L("Their citizens generate 2x the unhappiness, unless you build a courthouse.")) }
                    Divider2()
                    button(L("Puppet"), key: .char("p")) { answer("Puppet") }
                    note(L("Puppeted cities do not increase your tech or policy cost.")); note(L("You have no control over the the production of puppeted cities.")); note(L("Puppeted cities also generate 25% less Science and Culture.")); if !mayNotAnnex { note(L("A puppeted city can be annexed at any time.")) }
                    Divider2()
                    let canRaze = s.canBeDestroyed(c, justCaptured: true)   // Unciv addRazeOption: city.canBeDestroyed(justCaptured = true)
                    button(L("Raze"), destructive: true, enabled: canRaze, key: .char("r")) { answer("Raze") }
                    note(canRaze ? L(mayNotAnnex ? "Razing the city puppets it, and starts burning the city to the ground." : "Razing the city annexes it, and starts burning the city to the ground.") : L("Original capitals and holy cities cannot be razed."))
                    if canRaze { note(L("The population will gradually dwindle until the city is destroyed.")) }
                }
            }
        case .CityTraded:
            if let c = city {
                Text(L("What would you like to do with the city of [\(c.name)]?")).font(Theme.heading(16)).multilineTextAlignment(.center)
                if c.originalOwner >= 0, let orig = s.civ(c.originalOwner), !s.player.isAtWar(with: orig.id) {
                    button(L("Liberate (city returns to [\(orig.nation)])"), key: .char("l")) { answer("Liberate") }
                    note(L("Liberating a city returns it to its original owner, giving you a massive relationship boost with them!"))
                    Divider2()
                }
            }
        case .DiplomaticMarriage:
            if let c = city {
                Text("\(L(c.name)): \(L("What would you like to do with the city?"))").font(Theme.heading(16)).multilineTextAlignment(.center)
                if s.isOneCityChallenger(s.playerId) {
                    // Unciv addDestroyOption: `city.destroyCity(overrideSafeties = true)`
                    button(L("Destroy"), destructive: true, key: .char("d")) { answer("Destroy") }
                    note(L("Destroying the city instantly razes the city to the ground."))
                } else {
                    // Unciv addAnnexOption / addPuppetOption: Annex disabled (not hidden) when the civ may not annex, and
                    // the same lines the conquered city's popup has
                    let mayNotAnnex = s.mayNotAnnexCities(s.playerId)
                    button(L("Annex"), enabled: !mayNotAnnex, key: .char("a")) { answer("Annex") }
                    if mayNotAnnex { note(L("Your civilization may not annex this city.")) }
                    else { note(L("Annexed cities become part of your regular empire.")); note(L("Their citizens generate 2x the unhappiness, unless you build a courthouse.")) }
                    Divider2()
                    button(L("Puppet"), key: .char("p")) { answer("Puppet") }   // `city.isPuppet = true; city.cityStats.update()`
                    note(L("Puppeted cities do not increase your tech or policy cost.")); note(L("You have no control over the the production of puppeted cities.")); note(L("Puppeted cities also generate 25% less Science and Culture.")); if !mayNotAnnex { note(L("A puppeted city can be annexed at any time.")) }
                }
            }
        case .RecapturedCivilian:
            if let uid = Int(alert.value), let u = s.unit(uid), let orig = s.civ(u.originalCiv), orig.isAlive {
                Text(L("Return [\(u.name)] to [\(orig.nation)]?")).font(Theme.heading(16)).multilineTextAlignment(.center)
                Divider2()
                Text(L("The [\(u.name)] we liberated originally belonged to [\(orig.nation)]. They will be grateful if we return it to them.")).font(Theme.body).multilineTextAlignment(.center)
            }
        case .GameHasBeenWon:
            // Unciv AlertPopup.addGameHasBeenWon
            if let v = s.victoryData, let winner = s.civ(v.winningCiv) {
                Text(L("[\(winner.nation)] has won a [\(v.victoryType)] Victory!")).font(Theme.body).multilineTextAlignment(.center)
            }
        case .TradeRequest:
            // Unciv TradePopup: the leader, both offer columns side by side (a resource says how many we own),
            // then the nation's tradeRequest line; the answers are the bottom buttons.
            if let offer = Int(alert.value).flatMap({ id in s.pendingOffers.first { $0.id == id } }), let them = s.civ(offer.from) {
                leader(them)
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 6) {
                        Text(L("[\(them.nation)]'s trade offer")).font(Theme.body)
                        Text(s.describe(offer.give, ownedBy: s.playerId, tail: offer.evTailGive, separator: "\n")).font(Theme.body).multilineTextAlignment(.center)
                    }
                    VStack(spacing: 6) {
                        Text(L("Our trade offer")).font(Theme.body)
                        Text(s.describe(offer.want, ownedBy: s.playerId, tail: offer.evTailWant, separator: "\n")).font(Theme.body).multilineTextAlignment(.center)
                    }
                }
                Divider2()
                if let line = them.nationDef?.tradeRequest, !line.isEmpty { Text(L(line)).font(Theme.body).multilineTextAlignment(.center) }
            }
        case .Event:
            // Unciv AlertPopup.addEvent: event text, then one button per matching choice.
            let parts = alert.value.split(separator: "|", maxSplits: 1).map(String.init)
            let unitId = parts.count > 1 ? Int(parts[1]) : nil
            if let e = s.rs.events.first(where: { $0.name == parts[0] }) {
                header(L(e.name), color: Theme.gold)
                if !e.text.isEmpty { Text(L(e.text)).font(Theme.body).multilineTextAlignment(.center) }
                ForEach(e.civilopediaText.filter { !$0.text.isEmpty }, id: \.text) { line in note(L(line.text)) }
                let choices = s.matchingChoices(e, civId: s.playerId, unitId: unitId)
                if choices.isEmpty { button(L("Close"), filled: true) { close() } }
                ForEach(choices) { ch in
                    VStack(spacing: 3) {
                        button(L(ch.name.isEmpty ? ch.text : ch.name), filled: true) { answer(ch.name.isEmpty ? ch.text : ch.name) }
                        if !ch.name.isEmpty && !ch.text.isEmpty { note(L(ch.text)) }
                        ForEach(ch.uniqueObjects.filter { !$0.text.isEmpty }, id: \.text) { u in note(L(u.text)) }
                    }
                }
            }
        }
    }

    /// Unciv AlertPopup: what each handler adds with addCloseButton / addButton - the Popup's bottomTable, in one row
    /// unless the handler calls row(). City choices and event choices are added to the content, as Unciv adds them.
    /// The keys are Unciv's: AlertPopup's own `addCloseButton(text)` (a close button with nothing else to do) adds
    /// KeyboardBinding.NextTurnAlternate (Space), `addCloseButton(text, Confirm / Cancel)` the Confirm Dialog / Cancel
    /// Dialog bindings ('y' / 'n'), the city options their fixed letters, TradePopup 'y' / 'n' / 'e'. Popup.addCloseButton
    /// also maps BACK (ESC) on every close button, and ESC runs all of them: where they all only close the popup that is
    /// ESC closing it (`esc: true`); where two or more carry different actions (war or not, friendship or not, the
    /// demand answered either way, the civilian returned or kept) Unciv runs every one of them in a row, which is not
    /// reproduced - ESC does nothing there.
    @ViewBuilder private var bottomButtons: some View {
        switch alert.type {
        case .StartIntro: button(L("Let's begin!"), filled: true, key: Self.space, esc: true) { close() }
        case .FirstContact:
            if let c = civ { button(L(c.isCityState ? "Excellent!" : "A pleasure to meet you."), filled: true, key: Self.space, esc: true) { close() } } else { closeButton }
        case .WarDeclaration, .RejectingDemand:
            // addWarDeclaration: two text-only close buttons; addRejectingDemand: "Very well." with Cancel
            if alert.type == .RejectingDemand || civ != nil { buttonRow { button(L("You'll pay for this!"), key: Self.space, esc: true) { close() }; button(L("Very well."), key: alert.type == .RejectingDemand ? Self.cancel : Self.space, esc: true) { close() } } } else { closeButton }
        case .Denounced:
            if let c = civ {
                buttonRow {
                    if s.canDeclareWar(s.playerId, on: c.id) { button(L("THIS MEANS WAR! (Declare war)"), destructive: true) { answer("THIS MEANS WAR! (Declare war)") } }
                    button(L("Very well."), filled: true, key: Self.cancel) { close() }
                }
            } else { closeButton }
        case .DeclarationOfFriendship:
            if let c = civ, !s.player.isAtWar(with: c.id) {
                buttonRow {
                    button(L("Declare Friendship ([30] turns)"), filled: true, key: Self.confirm) { answer("Declare Friendship ([30] turns)") }
                    button(L("We are not interested."), key: Self.cancel) { answer("We are not interested.") }
                }
            } else { closeButton }
        case .BorderConflict:
            if civ != nil { buttonRow { button(L("Sorry."), key: Self.confirm, esc: true) { close() }; button(L("Never!"), key: Self.cancel, esc: true) { close() } } } else { closeButton }
        case .TilesStolen, .WonderBuilt, .TechResearched, .GoldenAge: closeButton
        case .DemandToStopSettlingCitiesNear, .DemandToStopSpreadingReligion, .DemandToStopSpyingOnUs, .DemandToNotAttackUs, .SpyingOnUsDespiteOurPromise:
            if civ != nil, let demand = Demand.forDemandAlert(alert.type) {
                buttonRow {
                    button(L(demand.acceptDemandText), filled: true, key: Self.confirm) { answer(demand.acceptDemandText) }
                    button(L(demand.refuseDemandText), destructive: demand == .DoNotAttackUs, key: Self.cancel) { answer(demand.refuseDemandText) }
                }
            } else { closeButton }
        case .CitySettledNearOtherCivDespiteOurPromise, .ReligionSpreadDespiteOurPromise, .AttackedUsDespitePromise, .AcceptingDemand:
            // addDemandViolationNoticed: a text-only close button; addAcceptingDemand: "Very well." with Cancel
            button(L("Very well."), filled: true, key: alert.type == .AcceptingDemand ? Self.cancel : Self.space, esc: true) { close() }
        case .BulliedProtectedMinor, .AttackedProtectedMinor, .AttackedAllyMinor:
            let parts = alert.value.split(separator: "@").compactMap { Int($0) }
            if parts.count == 2, let bully = s.civ(parts[0]), s.civ(parts[1]) != nil {
                let warOffered = !s.player.isAtWar(with: bully.id)
                buttonRow {
                    // Unciv AlertPopup: offered whenever we are not at war with them - no peace-treaty check (DeclareWar has none)
                    // Both "THIS MEANS WAR!" and "You'll pay for this!" take Confirm there, and a press runs both; ours
                    // binds it only while "You'll pay for this!" is the one button that has it
                    if warOffered {
                        button(L("THIS MEANS WAR!"), destructive: true) { answer("THIS MEANS WAR!") }
                    }
                    button(L("You'll pay for this!"), key: warOffered ? nil : Self.confirm) { answer("You'll pay for this!") }
                    button(L("Very well."), key: Self.cancel) { answer("Very well.") }
                }
            } else { closeButton }
        case .Defeated: button(L("Farewell."), filled: true, key: Self.space, esc: true) { close() }
        case .CityConquered, .DiplomaticMarriage: if city == nil { closeButton }
        case .CityTraded: if city != nil { button(L("Keep it"), filled: true, key: Self.space, esc: true) { close() } } else { closeButton }
        case .RecapturedCivilian:
            if let uid = Int(alert.value), let u = s.unit(uid), let orig = s.civ(u.originalCiv), orig.isAlive {
                buttonRow {
                    button(L("Yes"), filled: true, key: Self.confirm) { answer("Yes") }
                    button(L("No"), key: Self.cancel) { answer("No") }
                }
            } else { closeButton }
        case .GameHasBeenWon:
            // Unciv addGameHasBeenWon: "Victory status" (addButton, no key) then row(), then the close button
            button(L("Victory status"), filled: true) { answer("Victory status") }
            closeButton
        case .TradeRequest:
            // Unciv TradePopup: three buttons, each on its own row, with the fixed keys 'y', 'n' and 'e'
            if let offer = Int(alert.value).flatMap({ id in s.pendingOffers.first { $0.id == id } }), s.civ(offer.from) != nil {
                button(L("Sounds good!"), filled: true, key: .char("y")) { answer("Sounds good!") }
                button(L("Not this time."), key: .char("n")) { answer("Not this time.") }
                // Unciv: close() drops the request without declining it, and the DiplomacyScreen opens on that trade
                button(L("How about something else..."), key: .char("e")) { answer("How about something else...") }
            } else { closeButton }
        case .Event:
            let name = alert.value.split(separator: "|", maxSplits: 1).map(String.init).first ?? ""
            if !s.rs.events.contains(where: { $0.name == name }) { closeButton }
        }
    }
    /// AlertPopup.addCloseButton() - "Close", Space and ESC
    private var closeButton: some View { button(L("Close"), filled: true, key: Self.space, esc: true) { close() } }
    /// Buttons side by side as Unciv's bottomTable lays them out; stacked when the row does not fit the popup.
    private func buttonRow<V: View>(@ViewBuilder _ v: () -> V) -> some View {
        let built = v()
        return ViewThatFits(in: .horizontal) { HStack(spacing: 8) { built }; VStack(spacing: 8) { built } }
    }

    // MARK: pieces
    /// Unciv AlertPopup.addLeaderName: LeaderIntroTable(civInfo) - Civilization.getLeaderDisplayName ("[leader] of [nation]"
    /// translated, " (AI)" / " (Human - Hotseat)" once several humans play) - and a separator
    private func leader(_ c: Civilization) -> some View {
        VStack(spacing: 6) {
            // LeaderIntroTable's onClick: openCivilopedia(civInfo.nation.makeLink()), the popup still there on return
            LeaderIntroView(civ: c, suffix: LeaderIntroView.suffix(c, controller.state))
                .contentShape(Rectangle()).onTapGesture { controller.civilopediaEntry = "Nation/\(c.nation)"; controller.showCivilopedia = true }
            Divider2()
        }
    }
    private func header(_ text: String, color: Color) -> some View { Text(text).font(Theme.heading(14)).foregroundStyle(color) }
    private func note(_ text: String) -> some View { Text(text).font(Theme.small).foregroundStyle(Theme.creamDim).multilineTextAlignment(.center) }
    /// A popup button's key: a KeyboardBinding (Unciv `addCloseButton(text, binding)`) or a fixed character (`keyShortcuts.add('a')`).
    enum PopupKey { case binding(String), char(Character) }
    static let space = PopupKey.binding("Next turn alternate")   // AlertPopup.addCloseButton(text): KeyboardBinding.NextTurnAlternate
    static let confirm = PopupKey.binding("Confirm Dialog")       // KeyboardBinding.Confirm
    static let cancel = PopupKey.binding("Cancel Dialog")         // KeyboardBinding.Cancel
    private func button(_ title: String, filled: Bool = false, destructive: Bool = false, enabled: Bool = true, key: PopupKey? = nil, esc: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { Text(title) }.buttonStyle(ThemedButtonStyle(filled: filled, destructive: destructive)).disabled(!enabled)
            .modifier(PopupKeyShortcut(key: key))
            // Popup.addCloseButton: `keyShortcuts.add(KeyCharAndCode.BACK)` - ESC, a second key on the same button
            .background { if esc && enabled { Button("", action: act).keyboardShortcut(.escape, modifiers: []).frame(width: 0, height: 0).opacity(0) } }
    }
}

/// Unciv TradePopup.TradeThanksPopup: after "Sounds good!", the leader again, "Excellent!" and Farewell.
struct TradeThanksView: View {
    @ObservedObject var controller: GameController
    let civId: Int
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().bleedIntoCutout()
            Panel(padding: 18, highlighted: true) {
                VStack(spacing: 12) {
                    if let c = controller.state.civ(civId) {
                        // Unciv TradePopup: the requesting civ's LeaderIntroTable, then a separator
                        LeaderIntroView(civ: c, suffix: LeaderIntroView.suffix(c, controller.state))
                            .contentShape(Rectangle()).onTapGesture { controller.civilopediaEntry = "Nation/\(c.nation)"; controller.showCivilopedia = true }
                        Divider2()
                    }
                    Text(L("Excellent!")).font(Theme.body)
                    // Unciv TradeThanksPopup: addCloseButton("Farewell.", KeyCharAndCode.SPACE) - Space, and ESC as every close button
                    Button(L("Farewell.")) { controller.tradeThanksFrom = nil }.buttonStyle(ThemedButtonStyle(filled: true))
                        .keyboardShortcut(.space, modifiers: [])
                        .background { Button("") { controller.tradeThanksFrom = nil }.keyboardShortcut(.escape, modifiers: []).frame(width: 0, height: 0).opacity(0) }
                }
            }
            .frame(maxWidth: 360)
            .padding(16)
        }
    }
}

/// AlertPopupView.PopupKey on a button: the binding's current key (none when it has none), or the fixed character.
private struct PopupKeyShortcut: ViewModifier {
    let key: AlertPopupView.PopupKey?
    func body(content: Content) -> some View {
        switch key {
        case .binding(let name)?: content.modifier(BindingShortcut(name: name))
        case .char(let c)?: content.keyboardShortcut(KeyEquivalent(c), modifiers: [])
        case nil: content
        }
    }
}
