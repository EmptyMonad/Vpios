// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Contextual one-time tips for new players. Each tip has a condition checked after every refresh.
struct TutorialTip: Identifiable {
    let id: String
    /// Its Tutorials.json entry: the text is looked up and translated when the tip is shown (Unciv
    /// TutorialController.getTutorial), not every time the world screen asks the tips' conditions - on every refresh,
    /// where translating all of them took 6 ms of each tap on the map
    let jsonName: String
    let condition: (GameState) -> Bool
    var text: String { Tutorial.text(jsonName, fallback: L(jsonName)) }
    var steps: [String] { Tutorial.steps(jsonName) }   // Unciv TutorialRender: one popup per step
}

enum Tutorial {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "epochs.tips") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "epochs.tips") }
    }
    static var seen: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "epochs.tipsSeen") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "epochs.tipsSeen") }
    }
    static func reset() { seen = [] }

    // MARK: tutorial tasks (Unciv Events.json "Tutorial Task: […]")
    /// `event`: the Events.json entry, whose choices RenderEvent draws as buttons (nil for the static fallback list).
    struct Task: Identifiable { let id: String; let title: String; let hint: String; var uniques: [Unique] = []; var event: EventDef? = nil }
    /// Unciv Events.json "Tutorial Task: [X]" entries, mapped onto the detection ids.
    static let eventIds: [String: String] = ["Move unit": "move", "Found city": "found", "Enter city screen": "city", "Pick technology": "tech", "Pick construction": "build", "Pass a turn": "turn", "Reassign worked tiles": "tiles", "Meet another civilization": "meet", "Open the options table": "options", "Construct an improvement": "improve", "Create a trade route": "trade", "Conquer a city": "conquer", "Move an air unit": "air", "See your stats breakdown": "stats"]
    /// Unciv WorldScreen.getCurrentTutorialTask: the ruleset's events with Floating presentation, in file order - Gods &
    /// Kings' Events.json "Tutorial Task: [X]" entries. A ruleset without them shows no task (Vanilla has no Events.json).
    static var tasks: [Task] {
        Ruleset.shared.events.filter { $0.presentation == .Floating }.map { e -> Task in
            let lines = e.civilopediaText.map { $0.text }.filter { !$0.isEmpty }
            return Task(id: e.tutorialTaskName ?? e.name, title: lines.first ?? e.name, hint: lines.dropFirst().joined(separator: " "), uniques: e.uniqueObjects, event: e)
        }
    }
    static var tasksDone: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "epochs.tasksDone") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "epochs.tasksDone") }
    }
    /// The detection code speaks in short ids ("move"); the ruleset and its conditionals speak in names
    /// ("Move unit"). Everything is recorded under the ruleset's name, as Unciv records it.
    private static let idToEventName: [String: String] = Dictionary(uniqueKeysWithValues: eventIds.map { ($0.value, $0.key) })
    static func complete(_ id: String) { markTaskDone(idToEventName[id] ?? id) }
    /// Unciv GameSettings.addCompletedTutorialTask: the task's name goes into the stored set once. Locked, because the
    /// world screen's turn runs on a background thread ("Mark tutorial [] complete", meeting a civ) while the player's
    /// own taps complete tasks on the main one.
    static func markTaskDone(_ key: String) {
        tasksLock.lock(); defer { tasksLock.unlock() }
        if !tasksDone.contains(key) { tasksDone = tasksDone.union([key]); GameEvents.post(.tutorialTaskDone(key)) }
    }
    private static let tasksLock = NSLock()

    /// Unciv EventChoice availability: a task is offered while its "Only available" uniques hold and none of
    /// its "Unavailable" ones do.
    static func nextTask(_ s: GameState) -> Task? {
        guard enabled else { return nil }
        let ctx = GameState.UniqueContext(civId: s.playerId)
        return tasks.first { task in
            for u in task.uniques {
                if u.pattern == "Only available", !s.conditionalsHold(u, ctx) { return false }
                if u.pattern == "Unavailable", s.conditionalsHold(u, ctx) { return false }
            }
            return true
        }
    }
    /// Unciv WorldScreen.getCurrentTutorialTask: the one task completed from the game state - "Create a trade route" once
    /// any of our cities is in the STORED citiesConnectedToCapitalToMediums, which holds the capital itself
    /// (CapitalConnectionsFinder seeds it with medium Start). Every other task is completed where Unciv completes it:
    /// founding a city (CityFounder), passing a turn, entering the city screen, picking a tech or a construction,
    /// reassigning a tile, moving a unit, the stats overview, the options (GameController / screens), meeting a civ
    /// (GameState.meetCiv), finishing an improvement (TurnManager.doWorkerTurn), conquering a city (Battle.conquerCity)
    /// and "Mark tutorial [] complete" - where ours also guessed them from the state (a city owned, any improvement,
    /// turn > 1, movement spent, a tech or a production chosen, a locked tile, a puppet), completing them for what an
    /// automation or the AI had done.
    static func detectTasks(_ s: GameState) {
        let me = s.player
        if tasksDone.contains("Create a trade route") { return }
        let connected = Set(s.civ(me.id)?.citiesConnectedToCapital ?? s.findCitiesConnectedToCapital(me.id))
        if s.cities(of: me.id).contains(where: { connected.contains($0.id) }) { complete("trade") }
    }

    /// Unciv TutorialTrigger set with Unciv's own trigger conditions (WorldScreen.displayTutorialsOnUpdate & friends);
    /// the text comes from the bundled Tutorials.json so the wording matches Unciv in every language.
    static func text(_ name: String, fallback: String = "") -> String {
        let steps = Ruleset.tutorials.first { $0.name == name }?.steps.filter { !$0.isEmpty } ?? []
        // The bundled text says Epochs; Unciv's translations key on the original wording, so translate the Unciv form and rename back.
        return steps.isEmpty ? fallback : steps.map { L($0.replacingOccurrences(of: "Epochs", with: "Unciv")).replacingOccurrences(of: "Unciv", with: "Unciv 4X") }.joined(separator: "\n")
    }
    /// Unciv TutorialController.getTutorial: the steps of the tutorial, translated; empty when the ruleset has none (the popup is then skipped).
    static func steps(_ name: String) -> [String] {
        let steps = Ruleset.tutorials.first { $0.name == name }?.steps.filter { !$0.isEmpty } ?? []
        return steps.map { L($0.replacingOccurrences(of: "Epochs", with: "Unciv")).replacingOccurrences(of: "Unciv", with: "Unciv 4X") }
    }
    static var tips: [TutorialTip] {
        func tip(_ id: String, _ jsonName: String, _ condition: @escaping (GameState) -> Bool) -> TutorialTip { TutorialTip(id: id, jsonName: jsonName, condition: condition) }
        let shownByItsScreen: (GameState) -> Bool = { _ in false }
        return [
            // Unciv WorldScreen.displayTutorialsOnUpdate
            tip("Introduction", "Introduction") { _ in true },
            tip("EnemyCityNeedsConqueringWithMeleeUnit", "EnemyCityNeedsConqueringWithMeleeUnit") { s in
                let me = s.player
                return s.cities.contains { c in c.civId != me.id && me.isAtWar(with: c.civId) && c.health <= 1 && s.units(of: me.id).contains { $0.coord.distance(to: c.coord) <= 2 } }
            },
            tip("AfterConquering", "After Conquering") { s in s.cities(of: s.playerId).contains { $0.acquiredTurn == s.turn - 1 && $0.originalOwner != s.playerId && $0.originalOwner >= 0 } },
            tip("InjuredUnits", "Injured Units") { s in s.units(of: s.playerId).contains { $0.health < 100 } },
            tip("Workers", "Workers") { s in s.units(of: s.playerId).contains { $0.def.isWorker && $0.isCivilian && !$0.isGreatPerson } },
            // Unciv WorldScreen.update: TechPolicyDiplomacyButtons.update shows the diplomacy button
            tip("OtherCivEncountered", "OtherCivEncountered") { s in !s.player.isSpectator && s.player.metCivs.contains { s.civ($0)?.isMajor == true } },
            // Unciv WorldScreen.showTutorialsOnNextTurn
            tip("SlowStart", "Slow Start") { _ in true },
            tip("CityExpansion", "City Expansion") { s in s.cities(of: s.playerId).contains { c in c.tiles.contains { $0 != c.coord && $0.distance(to: c.coord) > 1 } } },   // CityExpansionManager.tilesClaimed() > 0
            tip("BarbarianEncountered", "BarbarianEncountered") { s in s.barbarianCivId.map { bid in s.units(of: bid).contains { b in s.visibleTiles(for: s.playerId).contains(b.coord) } } ?? false },
            tip("RoadsAndRailroads", "Roads and Railroads") { s in s.cities(of: s.playerId).count > 2 },
            tip("Happiness", "Happiness") { s in s.happiness(of: s.playerId) < 5 },
            tip("Unhappiness", "Unhappiness") { s in s.happiness(of: s.playerId) < 0 },
            tip("GoldenAge", "Golden Age") { s in s.player.isInGoldenAge },
            tip("IdleUnits", "Idle Units") { s in s.uncivTurns >= 50 && UserSettings.checkForDueUnits },   // Unciv WorldScreen: gameInfo.turns
            tip("ContactMe", "Contact Me") { s in s.uncivTurns >= 100 },
            // Unciv filters detailedCivResources for origin == "All", an origin only summarizedCivResourceSupply
            // (CivInfoTransientCache.updateCivResources: sumByResource("All")) carries, so neither trigger ever fires there
            tip("LuxuryResource", "Luxury Resource") { _ in false },
            tip("StrategicResource", "Strategic Resource") { _ in false },
            tip("EnemyCity", "Enemy City") { s in s.cities.contains { c in c.civId != s.playerId && s.player.isAtWar(with: c.civId) && s.player.explored.contains(c.coord) } },
            tip("Embarking", "Embarking") { s in s.civUniques(s.playerId).contains { $0.pattern == "Enables embarkation for land units" } },
            tip("NaturalWonders", "Natural Wonders") { s in s.player.explored.contains { s.map[$0]?.naturalWonder != nil } },
            tip("WeLoveTheKingDay", "We Love The King Day") { s in s.cities(of: s.playerId).contains { !$0.demandedResource.isEmpty } },
            // Unciv StatusTable: the city button of a blockaded city
            tip("CityBlockade", "City Blockade") { s in s.cities(of: s.playerId).contains { s.isCityBlockaded($0) } },
            // Shown when their screen opens: PolicyPickerScreen, PromotionPickerScreen, CityScreen (a blockaded tile)
            tip("CultureAndPolicies", "Culture and Policies", shownByItsScreen),
            tip("Experience", "Experience", shownByItsScreen),
            tip("CityTileBlockade", "City Tile Blockade", shownByItsScreen),
        ]
    }

    /// The first unseen tip whose condition currently holds.
    static func next(for state: GameState) -> TutorialTip? {
        guard enabled else { return nil }
        let done = seen
        return tips.first { !done.contains($0.id) && $0.condition(state) }
    }
}
