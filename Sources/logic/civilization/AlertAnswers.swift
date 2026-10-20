// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv AlertPopup / TradePopup: the answers a popup offers and what each one does to the game - the button lambdas,
/// here on the game so the popup view, the headless drivers and the tests all
/// press the same buttons. An option's id is Unciv's (untranslated) button text.
struct AlertOption: Equatable {
    let id: String
    var enabled = true
}
struct AlertOptions: Equatable {
    /// In the order the popup adds its buttons (AlertPopup's content buttons first where it adds them there).
    var options: [AlertOption] = []
    /// Unciv Popup.addCloseButton: `clickBehindToClose = true; onCloseCallback = action` - tapping behind the popup closes
    /// it and runs the LAST close button's action (getBehindClickListener), unless forbidPopupClickBehindToClose. nil
    /// for a popup with no close button (CityConquered, DiplomaticMarriage, an event, TradePopup): tapping behind does
    /// nothing there.
    var clickBehind: String? = nil
    var enabled: [String] { options.filter(\.enabled).map(\.id) }
}

extension GameState {
    static let alertClose = "Close"   // Unciv Constants.close

    /// The buttons AlertPopup (TradePopup for a .TradeRequest) shows `civId` for this alert, Unciv's handler by handler;
    /// none when the handler would not open it (shouldOpen false - the alert is dropped).
    func alertOptions(_ a: PopupAlert, for civId: Int) -> AlertOptions {
        guard alertShouldOpen(a, for: civId) else { return AlertOptions() }
        var o = AlertOptions()
        func close(_ id: String) { o.options.append(AlertOption(id: id)); o.clickBehind = id }   // addCloseButton
        func button(_ id: String, enabled: Bool = true) { o.options.append(AlertOption(id: id, enabled: enabled)) }   // addButton / add(button)
        let other = Int(a.value).flatMap { civ($0) }
        switch a.type {
        case .BorderConflict: close("Sorry."); close("Never!")
        case .TilesStolen, .WonderBuilt, .TechResearched, .GoldenAge: close(GameState.alertClose)
        case .BulliedProtectedMinor, .AttackedProtectedMinor, .AttackedAllyMinor:
            let parts = a.value.split(separator: "@").compactMap { Int($0) }
            if parts.count == 2, !areAtWar(civId, parts[0]) { close("THIS MEANS WAR!") }
            close("You'll pay for this!"); close("Very well.")
        case .CityConquered:
            guard let c = Int(a.value).flatMap({ city($0) }) else { break }
            // `city.foundingCivObject != null && city.civ != city.foundingCivObject && conqueringCiv != city.foundingCivObject`
            if c.originalOwner >= 0, civ(c.originalOwner) != nil, c.civId != c.originalOwner, civId != c.originalOwner { button("Liberate") }
            if isOneCityChallenger(civId) { button("Destroy") }
            else {
                let mayAnnex = !mayNotAnnexCities(civId)
                button("Annex", enabled: mayAnnex); button("Puppet"); button("Raze", enabled: canBeDestroyed(c, justCaptured: true))
            }
        case .CitySettledNearOtherCivDespiteOurPromise, .ReligionSpreadDespiteOurPromise, .AttackedUsDespitePromise: close("Very well.")
        case .CityTraded:
            // `if (!conqueringCiv.isAtWarWith(city.foundingCivObject!!))` - Liberate (an add(button)), then "Keep it"
            if let c = Int(a.value).flatMap({ city($0) }), c.originalOwner >= 0, !areAtWar(civId, c.originalOwner) { button("Liberate") }
            close("Keep it")
        case .DeclarationOfFriendship: close("Declare Friendship ([30] turns)"); close("We are not interested.")
        case .Denounced:
            if let d = other, canDeclareWar(civId, on: d.id) { close("THIS MEANS WAR! (Declare war)") }
            close("Very well.")
        case .Defeated: close("Farewell.")
        // AlertPopup: `SpyingOnUsDespiteOurPromise -> addDemand(Demand.DontSpyOnUs)` - the demand popup again, both answers
        case .DemandToStopSettlingCitiesNear, .DemandToStopSpreadingReligion, .DemandToStopSpyingOnUs, .DemandToNotAttackUs, .SpyingOnUsDespiteOurPromise:
            if let demand = Demand.forDemandAlert(a.type) { close(demand.acceptDemandText); close(demand.refuseDemandText) }
        case .AcceptingDemand: close("Very well.")
        case .RejectingDemand: close("You'll pay for this!"); close("Very well.")
        case .DiplomaticMarriage:
            if isOneCityChallenger(civId) { button("Destroy") }
            else { button("Annex", enabled: !mayNotAnnexCities(civId)); button("Puppet") }
        case .FirstContact: close(other?.isCityState == true ? "Excellent!" : "A pleasure to meet you.")
        case .GameHasBeenWon: button("Victory status"); close(GameState.alertClose)
        case .RecapturedCivilian: close("Yes"); close("No")
        case .StartIntro: close("Let's begin!")
        case .WarDeclaration: close("You'll pay for this!"); close("Very well.")
        case .Event:
            let parts = a.value.split(separator: "|", maxSplits: 1).map(String.init)
            if let e = rs.events.first(where: { $0.name == parts.first }) {
                for ch in matchingChoices(e, civId: civId, unitId: parts.count > 1 ? Int(parts[1]) : nil) { button(ch.name.isEmpty ? ch.text : ch.name) }
            }
        case .TradeRequest: button("Sounds good!"); button("Not this time."); button("How about something else...")
        }
        return o
    }

    /// `civId` presses `option` on this alert's popup: the button's lambda, then AlertPopup.close (`popupAlerts.remove`) -
    /// for addCloseButton Unciv closes first and runs the action after, for the city choices the action comes first; no
    /// handler reads the popup queue, so the order does not show. TradePopup's buttons, for a .TradeRequest. An option the
    /// popup does not offer (or offers disabled) does nothing and returns false.
    @discardableResult
    func answerAlert(_ civId: Int, _ a: PopupAlert, option: String) -> Bool {
        guard alertOptions(a, for: civId).enabled.contains(option) else { return false }
        let other = Int(a.value)
        switch a.type {
        case .CityConquered:
            guard let cityId = other else { break }
            switch option {
            case "Liberate": liberateCity(cityId: cityId, by: civId)
            case "Destroy": destroyConqueredCity(cityId: cityId, by: civId)          // puppetCity, destroyCity
            case "Annex": annexConqueredCity(cityId: cityId, by: civId)              // puppetCity, annexCity
            case "Puppet": puppetConqueredCity(cityId: cityId, by: civId)            // puppetCity
            case "Raze": razeConqueredCity(cityId: cityId, by: civId)                // puppetCity, annexCity if allowed, isBeingRazed
            default: break
            }
        case .CityTraded:
            if option == "Liberate", let cityId = other { liberateCity(cityId: cityId, by: civId) }
        case .DiplomaticMarriage:
            guard let cityId = other else { break }
            switch option {
            case "Destroy": destroyCity(cityId: cityId, overrideSafeties: true)      // `city.destroyCity(overrideSafeties = true)`
            case "Annex": annexCity(cityId: cityId)                                  // `annexAction()` is empty, then `city.annexCity()`
            case "Puppet":
                // `city.isPuppet = true; city.cityStats.update()`
                if let ci = cityIndex(cityId) { cities[ci].isPuppet = true }
                updateCityStats(cityId, reason: "AlertPopup.addDiplomaticMarriage")
            default: break
            }
        case .DeclarationOfFriendship:
            guard let o = other else { break }
            if option == "Declare Friendship ([30] turns)" { declareFriendship(civId, o) }   // playerDiploManager.signDeclarationOfFriendship()
            else { setFlag(o, civId, "DeclinedDeclarationOfFriendship", 20) }              // otherCivDiplomacy().setFlag(Declined.., 20)
        case .Denounced:
            if option == "THIS MEANS WAR! (Declare war)", let o = other { declareWar(civId, on: o) }
        case .DemandToStopSettlingCitiesNear, .DemandToStopSpreadingReligion, .DemandToStopSpyingOnUs, .DemandToNotAttackUs, .SpyingOnUsDespiteOurPromise:
            guard let o = other, let demand = Demand.forDemandAlert(a.type) else { break }
            if option == demand.acceptDemandText { agreeToDemand(demand, from: o, by: civId) }
            else {
                // `playerDiploManager.refuseDemand(demand)` - which already declares war for DoNotAttackUs - and then
                // `if (demand == Demand.DoNotAttackUs) viewingCiv.getDiplomacyManager(otherciv)!!.declareWar()`: DeclareWar asks
                // nothing of the war, so the declaration runs a second time (notifications, the demander's WarDeclaration
                // alert, WarMongerer and SharedEnemy once more)
                refuseDemand(demand, from: o, by: civId)
                if demand == .DoNotAttackUs { declareWar(civId, on: o, evenAtWar: true) }
            }
        case .BulliedProtectedMinor, .AttackedProtectedMinor, .AttackedAllyMinor:
            let parts = a.value.split(separator: "@").compactMap { Int($0) }
            guard parts.count == 2 else { break }
            let bully = parts[0], cs = parts[1]
            switch option {
            case "THIS MEANS WAR!":
                sideWithCityState(civId, bully: bully)
                // DeclareWarReason(AlliedCityStateWar / ProtectedCityStateWar, cityState): both take DeclareWar's branch of
                // CityStateAllianceWar - the same notifications, no warmongering - and nothing else reads the two
                declareWar(civId, on: bully, warType: .cityStateAllianceWar, allyCiv: cs)
                // `cityState.getDiplomacyManager(player)!!.influence += 20f` - the raw field: no clamp, no ally update
                if let ci = civIndex(cs) { civs[ci].influence[civId] = Double(Float(civs[ci].influence[civId] ?? 0) + 20) }
            case "You'll pay for this!": sideWithCityState(civId, bully: bully)
            case "Very well.":
                // the broken pledge's notification first, then removeProtectorCiv(player, forced = true)
                if let csName = civ(cs)?.nation {
                    notify(civId, "You have broken your Pledge to Protect [\(csName)]!", category: .Diplomacy, icons: [csName],
                           actions: (capital(of: cs).map { [NotificationAction.location($0.coord)] } ?? []) + [.diplomacy(csName)])
                }
                withdrawProtection(civId, cs, forced: true)
            default: break
            }
        case .RecapturedCivilian:
            guard let unitId = other else { break }
            if option == "Yes" { returnCapturedUnit(unitId: unitId, by: civId) } else { keepCapturedUnit(unitId: unitId, by: civId) }
        case .Event:
            let parts = a.value.split(separator: "|", maxSplits: 1).map(String.init)
            let unitId = parts.count > 1 ? Int(parts[1]) : nil
            if let e = rs.events.first(where: { $0.name == parts.first }),
               let ch = matchingChoices(e, civId: civId, unitId: unitId).first(where: { ($0.name.isEmpty ? $0.text : $0.name) == option }) {
                triggerChoice(ch, civId: civId, unitId: unitId)
            }
        case .TradeRequest:
            guard let id = other else { break }
            switch option {
            case "Sounds good!": respondToOffer(id, accept: true)
            case "Not this time.": respondToOffer(id, accept: false)
            default: pendingOffers.removeAll { $0.id == id }   // close(): the request goes, nothing declined
            }
        default: break   // close buttons with nothing else to do ("Victory status" pushes a screen)
        }
        dismissAlert(civId, a)
        return true
    }

    /// Unciv WorldScreen.update, before a TradePopup opens (no other popup alert left): `for (tradeRequest in
    /// viewingCiv.tradeRequests.toList()) if (!TradeEvaluation().isTradeValid(...)) viewingCiv.tradeRequests.remove(tradeRequest)`
    /// - "In the meantime this became invalid, perhaps because we accepted previous trades": the request goes, undeclined,
    /// and with it its alert. Ours had the popup pass it over and left the request standing until the civ's next automation.
    func sweepInvalidTradeRequests(_ civId: Int) {
        let invalid = pendingOffers.filter { $0.to == civId && !$0.isFriendshipRequest && !tradeIsValid($0) }.map(\.id)
        guard !invalid.isEmpty else { return }
        pendingOffers.removeAll { invalid.contains($0.id) }
        if let ci = civIndex(civId) {
            let kept = civs[ci].popupAlerts.filter { a in !(a.type == .TradeRequest && Int(a.value).map { invalid.contains($0) } == true) }
            civs[ci].popupAlerts = kept
        }
    }

    /// Unciv DiplomacyManager.sideWithCityState, on `civId`'s manager towards the bully: the bully's side remembers it.
    func sideWithCityState(_ civId: Int, bully: Int) {
        setModifier(bully, civId, .SidedWithProtectedMinor, -5)
        setFlag(bully, civId, "RememberSidedWithProtectedMinor", 25)
    }
}
