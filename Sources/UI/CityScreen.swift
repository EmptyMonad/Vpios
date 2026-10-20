// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv ConfirmPopup for purchases: prompt text plus the action to run on "Purchase".
struct PurchasePrompt: Identifiable { let id = UUID(); let text: String; let action: () -> Void }

struct CityScreen: View {
    @ObservedObject var controller: GameController
    let cityId: Int
    @State private var sellCandidate: String? = nil
    @State private var purchasePrompt: PurchasePrompt? = nil
    @State private var selectedConstruction: Production? = nil   // Unciv CityScreen.selectedConstruction
    @State private var constructionMenu: Production? = nil   // Unciv CityScreenConstructionMenu (long press on a construction)
    @State private var perpetualMenu: String? = nil   // the same menu for a PerpetualConstruction (convertProductionTo)
    @State private var selectedQueueEntry = -1   // Unciv CityConstructionsTable.selectedQueueEntry (index in the combined queue, -1 none)
    @State private var noSpaceText: String? = nil   // Unciv purchaseConstruction failure popup
    @State private var modelBox = CityScreenModel.Box()

    var body: some View {
        let umT = UIMeasure.start()
        let v = screen
        UIMeasure.stop("CityScreen.body", umT)
        return v.screenShown("city")
    }
    /// What the screen shows of the game (CityScreenModel), for this city as the game stands. Unciv works its tables out
    /// once per CityScreen.update, after each action; this body runs on every publish of the controller, so the model is
    /// kept until the game changes (its Key) and read from instead - and kept as it is while the screen is going away.
    private func model(_ city: City) -> CityScreenModel {
        let key = CityScreenModel.Key(state: ObjectIdentifier(controller.state), revision: controller.revision, cityId: city.id, viewerId: controller.viewCivId)
        if let m = modelBox.model, modelBox.key == key || (!controller.showCity && m.city.id == city.id) { return m }
        let umT = UIMeasure.start(); defer { UIMeasure.stop("CityScreenModel.new", umT) }
        let m = CityScreenModel(state: controller.state, city: city, viewerId: controller.viewCivId)
        modelBox.key = key; modelBox.model = m
        CityScreenModel.shown = m
        return m
    }
    /// The constructions table's stacks: lazy, so a row - and the turns and prices under its name - is only built when it
    /// scrolls into view (Unciv builds the whole table, but a Scene2D label costs next to nothing to lay out); all at
    /// once for the self-test's dump, which reads every row as rendered
    @ViewBuilder private func lazyStack<C: View>(alignment: HorizontalAlignment, spacing: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        if CityScreenModel.eagerLists { VStack(alignment: alignment, spacing: spacing, content: content) }
        else { LazyVStack(alignment: alignment, spacing: spacing, content: content) }
    }
    @ViewBuilder private var screen: some View {
        let s = controller.state
        if let city = s.city(cityId) {
            let m = model(city)
            // Unciv CityScreen: the city's tiles fill the screen; the constructions table sits top left, the stats table
            // top right, the selected construction or tile bottom right, the annex/raze button top centre and the city
            // picker with the "Exit city" button bottom centre - all floating over the map.
            GeometryReader { geo in
                let sideWidth = min(geo.size.width * 0.32, 340)
                ZStack {
                    Theme.bg.ignoresSafeArea().bleedIntoCutout()
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        CityMapView(controller: controller, model: m, scale: 1.25 * Theme.uiScale,
                                    targetTile: selectedConstruction.flatMap { s.improvementToCreate($0) != nil ? city.reservedImprovementTile : nil },
                                    selectedTile: controller.cityTile, pickTile: controller.cityPickTile,
                                    onPickTile: { tile in pickedTile(tile, city: city) })
                            .equatable()
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                    .defaultScrollAnchor(.center)
                    HStack(alignment: .top, spacing: 0) {
                        // Unciv CityScreen.isSpying: a foreign city's constructions table is hidden
                        if city.civId == s.playerId {
                            ScrollView(showsIndicators: false) { lazyStack(alignment: .leading, spacing: 8) { constructionsSection(m) }.padding(8) }
                                .frame(width: sideWidth)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelDark.opacity(0.92)))
                        }
                        Spacer(minLength: 8)
                        statsPanel(m)
                            .frame(width: sideWidth)
                            .frame(maxHeight: geo.size.height * (controller.cityTile != nil || selectedConstruction != nil ? 0.55 : 1), alignment: .top)
                    }
                    .padding(8)
                    // top centre: annex / raze
                    // (Unciv razeCityButtonHolder: stage.height - 20, Align.top, over the map). A disabled Unciv TextButton
                    // keeps its solid grey skin; ours is a translucent fill dimmed to 38%, which let the map's tiles run
                    // through the label - it sits on the panel colour so the map stays behind it
                    VStack {
                        annexRazeButton(m).background(RoundedRectangle(cornerRadius: Theme.R.control, style: .continuous).fill(Theme.panelDark))
                        Spacer()
                    }.padding(.top, 8)
                    // bottom right: the selected tile or construction
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Group {
                                if let t = controller.cityTile { CityTileTable(controller: controller, model: m, coord: t) }
                                else if let sel = selectedConstruction, city.civId == s.playerId { selectedPanel(sel, m: m, canChange: canCityBeChanged(city)) }
                            }
                            .frame(maxWidth: sideWidth)
                        }
                    }.padding(8)
                    // bottom centre: city picker and exit button
                    VStack(spacing: 6) {
                        Spacer()
                        CityPickerRow(controller: controller, city: city)
                        Button(L("Exit city")) { controller.exitCityScreen() }.buttonStyle(ThemedButtonStyle(compact: true))
                    }
                    .padding(.bottom, 8)
                    CityKeyboardShortcuts(controller: controller)
                }
                .foregroundStyle(Theme.cream)
            }
            // Unciv CityScreen.updateTileGroups: a blockaded tile of the viewing civ's city shows the CityTileBlockade tutorial.
            // The task runs after the body that made it, so it reads the controller's game as it is then, not the body's
            // `s`: Next Turn with AutoPlay may have handed that game to the turn's thread meanwhile (showWhileAutomating),
            // which writes it while the screen shows a copy - ThreadSanitizer caught this read racing
            // respondToPopupAlerts in a --bg-turn-selftest 20 run.
            .task(id: city.id) {
                let s = controller.state
                if let city = s.city(cityId), city.civId == s.playerId && city.tiles.contains(where: { s.isBlockaded($0, for: s.playerId) }) { controller.displayTutorial("CityTileBlockade") }
            }
            // Unciv CityScreen.page / "Move to city" / the city picker build a new CityScreen(city) without initSelectedConstruction
            // or initSelectedTile: the other city opens with nothing selected (selectedQueueEntry -1, no pickTileData)
            .onChange(of: cityId) { _, _ in
                selectedConstruction = nil; selectedQueueEntry = -1; constructionMenu = nil; perpetualMenu = nil; sellCandidate = nil; purchasePrompt = nil; noSpaceText = nil
                controller.cityPickTile = nil; controller.cityTile = nil
            }
            // Unciv CityScreen.selectTile / selectConstruction: one clears the other
            .onChange(of: controller.cityTile) { _, t in if t != nil { selectedConstruction = nil; selectedQueueEntry = -1; controller.cityPickTile = nil } }
            // Unciv selectConstruction: anything but a CreatesOneImprovement building drops the tile picking
            .onChange(of: selectedConstruction) { _, c in if c != nil { controller.cityTile = nil }; if c.flatMap({ s.improvementToCreate($0) }) == nil { controller.cityPickTile = nil } }
            .onDisappear { controller.cityPickTile = nil }
            // --city-screen-selftest --dump selects each construction as a tap on its row does, to read its info table
            .onAppear { if CityScreenSelfTest.request?.dump == true { let b = $selectedConstruction; CityScreenSelfTest.selectConstruction = { b.wrappedValue = $0 } } }
            .modifier(CityScreenPopups(controller: controller, city: city, sellCandidate: $sellCandidate, onSold: { selectedConstruction = nil; selectedQueueEntry = -1; controller.cityTile = nil }, era: s.rs.era(named: s.player.eraName)))
            .confirmationDialog(purchasePrompt?.text ?? "", isPresented: Binding(get: { purchasePrompt != nil }, set: { if !$0 { purchasePrompt = nil } }), titleVisibility: .visible) {
                if let pp = purchasePrompt { Button(L("Purchase")) { pp.action(); purchasePrompt = nil } }
                Button(L("Cancel"), role: .cancel) {}   // Unciv ConfirmPopup's "Cancel" (the system's stays in English)
            }
            .alert(noSpaceText ?? "", isPresented: Binding(get: { noSpaceText != nil }, set: { if !$0 { noSpaceText = nil } })) { Button(L("Close")) { noSpaceText = nil } }
            .overlay { if let p = constructionMenu { ConstructionMenuView(controller: controller, city: city, production: p, onClose: { constructionMenu = nil }) } }
            .overlay { if let n = perpetualMenu { PerpetualConstructionMenuView(controller: controller, city: city, name: n, onClose: { perpetualMenu = nil }) } }
        } else {
            // Unciv's CityScreen holds the City itself and has no screen for a missing one: a city gone while its screen
            // was asked for (the console's removal) just closes it
            Color.clear.onAppear { controller.showCity = false }
        }
    }

    /// Unciv CityScreen.updateAnnexAndRazeCityButton
    @ViewBuilder
    private func annexRazeButton(_ m: CityScreenModel) -> some View {
        let city = m.city, s = controller.state
        let canChange = controller.isMyTurn && city.civId == s.playerId
        if city.civId == s.playerId {
            if city.isPuppet && m.canAnnex { Button(L("Annex city")) { controller.annexSelected() }.buttonStyle(ThemedButtonStyle(filled: true, compact: true)).disabled(!canChange) }
            else if !city.razing { Button(L("Raze city")) { controller.toggleRaze() }.buttonStyle(ThemedButtonStyle(destructive: true, compact: true)).disabled(!canChange || !m.canRaze || !m.canAnnex) }
            else { Button(L("Stop razing city")) { controller.toggleRaze() }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(!canChange) }
        }
    }

    /// Unciv CityStatsTable: an expander whose header is the MiniStatsTable, over a scrolling lower table - the Stats
    /// button, the texts, citizen management, great people, specialists, religion and buildings.
    private func statsPanel(_ m: CityScreenModel) -> some View {
        let city = m.city, s = controller.state, stats = m.stats
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Unciv MiniStatsTable walks Stat.entries; each icon is also that stat's focus button
                yield("⚙️", stats.total.production, stat: "Production", city: city); yield("🍎", stats.foodSurplus, stat: "Food", city: city); yield("💰", stats.total.gold - Double(stats.maintenance), stat: "Gold", city: city)
                yield("🔬", stats.total.science, stat: "Science", city: city); yield("🎵", stats.total.culture, stat: "Culture", city: city)
                yield("😊", m.happiness, stat: "Happiness", city: city)
                if s.religionEnabled { yield("🕊", stats.total.faith, stat: "Faith", city: city) }
            }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    Button(L("Stats")) { controller.showDetailedStats = true }.buttonStyle(ThemedButtonStyle(compact: true))
                    // addText: the unassigned-population label reassigns the citizens when tapped
                    Button { if controller.isMyTurn && city.civId == s.playerId { controller.tryReassignPopulation(city.id); controller.refresh(full: false) } } label: {
                        Text(L("Unassigned population") + ": \(max(0, m.freePopulation))/\(city.population)").font(Theme.caption)
                    }.buttonStyle(.plain)
                    Text(m.expansionText).font(Theme.caption)
                    Text(m.populationText).font(Theme.caption)
                    if city.resistanceTurns > 0 { Text("✊ " + L("In resistance for another [\(city.resistanceTurns)] turns")).font(Theme.caption) }
                    // addText resourceTable: the city-level resources this city has (supply and stockpile), each opening its Civilopedia page
                    let cityWide = m.cityWideResources
                    if !cityWide.isEmpty {
                        HStack(spacing: 10) {
                            ForEach(cityWide, id: \.0) { r in
                                Button { controller.civilopediaEntry = "Resource/\(r.0)"; controller.showCivilopedia = true } label: {
                                    HStack(spacing: 4) { ArtIcon(name: r.0, folder: "ResourceIcons", fallback: "cube", size: 18); Text(Translations.shared.numberTr(r.1)).font(Theme.caption) }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if city.isCelebrating || !city.demandedResource.isEmpty {
                        Button { controller.civilopediaEntry = "Tutorial/We Love The King Day"; controller.showCivilopedia = true } label: {
                            if city.isCelebrating { Text("🍎 " + L("We Love The King Day for another [\(city.wltkdTurns)] turns")).font(Theme.caption).foregroundStyle(Color(red: 0.2, green: 0.8, blue: 0.2)) }
                            else { Text(L("Demanding [\(city.demandedResource)]")).font(Theme.caption).foregroundStyle(Color(red: 1, green: 0.5, blue: 0.31)) }
                        }.buttonStyle(.plain)
                    }
                    citizenManagement(city, s: s)
                    greatPeople(m)
                    SpecialistAllocationView(controller: controller, city: city)
                    CityReligionInfoView(controller: controller, city: city)
                    buildingsInfo(city, s: s)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelDark.opacity(0.92)))
    }

    /// Unciv CitizenManagementTable (an expander that starts closed)
    private func citizenManagement(_ city: City, s: GameState) -> some View {
        DisclosureGroup {
            let canManage = controller.isMyTurn && city.civId == s.playerId && !city.isPuppet
            let focuses = GameState.cityFocuses.filter { $0.tableEnabled && ($0.stat != "Faith" || s.religionEnabled) }
            let ownRow: Set<String> = ["NoFocus", "Manual"]
            VStack(alignment: .leading, spacing: 4) {
                // Unciv CitizenManagementTable.topTable: Reset Citizens and Avoid Growth side by side
                HStack(spacing: 4) {
                    Button { controller.resetCitizens() } label: { Text(L("Reset Citizens")).font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity) }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(!canManage)
                    Button { controller.toggleAvoidGrowth() } label: { Text(L("Avoid Growth")).font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity) }.buttonStyle(ThemedButtonStyle(filled: city.avoidGrowth, compact: true)).disabled(!canManage)
                }
                Text(L("Citizen Focus")).font(Theme.small.bold()).foregroundStyle(Theme.gold)
                // Unciv: NoFocus and Manual share a row of their own; the other focuses go four to a row (numCol = 4)
                HStack(spacing: 4) { ForEach(focuses.filter { ownRow.contains($0.name) }, id: \.name) { f in focusButton(f, city, canManage) } }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(focuses.filter { !ownRow.contains($0.name) }, id: \.name) { f in focusButton(f, city, canManage) }
                }
            }
        } label: { Text(L("Citizen Management")).font(Theme.caption.bold()).foregroundStyle(Theme.gold) }
        .tint(Theme.gold)
    }

    /// Unciv CitizenManagementTable focus cell: trySetCityFocus, the current focus highlighted
    private func focusButton(_ f: GameState.CityFocus, _ city: City, _ canManage: Bool) -> some View {
        Button { controller.setCityFocus(f.name) } label: { Text(f.stat == nil ? L(f.label) : f.label).font(.system(size: 11, weight: .semibold)).lineLimit(1).frame(maxWidth: .infinity) }
            .buttonStyle(ThemedButtonStyle(filled: city.cityFocus == f.name, compact: true)).disabled(!canManage)
    }

    /// Unciv CityStatsTable.addGreatPersonPointInfo
    @ViewBuilder
    private func greatPeople(_ m: CityScreenModel) -> some View {
        let rows = m.greatPeople
        if !rows.isEmpty {
            Text(L("Great People")).font(Theme.caption.bold()).foregroundStyle(Theme.gold)
            ForEach(rows, id: \.name) { g in
                HStack(spacing: 6) {
                    // the info opens this great person's breakdown; the portrait opens all of them
                    Button { controller.gppBreakdownPerson = g.name; controller.showGPPBreakdown = true } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                ArtIcon(name: g.name, folder: "UnitIcons", fallback: "star.fill", size: 18)
                                Text(L("{\(g.name)} (+\(Int(g.perTurn.rounded())))")).font(Theme.small)
                            }
                            ZStack {
                                ProgressView(value: min(1, g.now / g.needed)).tint(.orange)
                                Text(L("\(Int(g.now))/\(Int(g.needed))")).font(.system(size: 10, weight: .bold))
                            }
                        }
                    }.buttonStyle(.plain)
                    Button { controller.gppBreakdownPerson = nil; controller.showGPPBreakdown = true } label: {
                        ArtIcon(name: g.name, folder: "UnitIcons", fallback: "star.fill", size: 30)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    /// Unciv CityStatsTable.addBuildingsInfo: "Buildings" with Specialist buildings, Wonders and Other, each sorted by name
    @ViewBuilder
    private func buildingsInfo(_ city: City, s: GameState) -> some View {
        if !city.buildings.isEmpty {
            DisclosureGroup {
                // addBuildingsInfo: wonders, then specialist buildings, then the rest - each alphabetical
                let isWonder: (String) -> Bool = { s.rs.buildings[$0]?.isAnyWonder == true }
                let hasSlots: (String) -> Bool = { !(s.rs.buildings[$0]?.specialistSlots.isEmpty ?? true) }
                let grouped: [(String, [String])] = [
                    ("Specialist Buildings", city.buildings.filter { !isWonder($0) && hasSlots($0) }.sorted()),
                    ("Wonders", city.buildings.filter(isWonder).sorted()),
                    ("Other", city.buildings.filter { !isWonder($0) && !hasSlots($0) }.sorted()),
                ]
                let calc = CityStats(city: city, state: s)
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(grouped.filter { !$0.1.isEmpty }, id: \.0) { title, list in
                        Text(L(title)).font(Theme.small.bold()).foregroundStyle(Theme.gold).frame(maxWidth: .infinity)
                        ForEach(list, id: \.self) { b in buildingButton(b, city: city, calc: calc, s: s) }
                    }
                }
            } label: { Text(L("Buildings")).font(Theme.caption.bold()).foregroundStyle(Theme.gold) }
            .tint(Theme.gold)
        }
    }

    /// addBuildingButton: "{name} ({Free})", the building's stats in this city and its specialist slots (filled ones in
    /// the specialist's colour), the portrait; a tap selects it (its info panel carries the Sell button)
    private func buildingButton(_ b: String, city: City, calc: CityStats?, s: GameState) -> some View {
        let free = s.hasFreeBuilding(city, b)   // Unciv cityScreen.hasFreeBuilding
        let stats = calc?.buildingStats(b) ?? (s.rs.buildings[b]?.stats ?? Stats())
        var assigned = city.specialists
        let slots = (s.rs.buildings[b]?.specialistSlots ?? [:]).sorted { $0.key < $1.key }
        return Button { selectedQueueEntry = -1; selectedConstruction = .building(b) } label: {
            HStack(spacing: 6) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(free ? L(b) + " (" + L("Free") + ")" : L(b)).font(Theme.caption)
                    HStack(spacing: 4) {
                        Text(stats.short).font(Theme.small).foregroundStyle(Theme.creamDim)
                        ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                            ForEach(0..<slot.value, id: \.self) { _ in
                                let filled = (assigned[slot.key] ?? 0) > 0
                                let _ = { if filled { assigned[slot.key, default: 0] -= 1 } }()
                                Image(systemName: "person.fill").font(.system(size: 10)).foregroundStyle(filled ? Theme.gold : Color.gray)
                            }
                        }
                    }
                }
                ArtIcon(name: b, folder: "BuildingIcons", fallback: "building.2.fill", size: 28)
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }.buttonStyle(.plain)
    }

    /// Unciv CityStatsTable.MiniStatsTable: ikona dokunmak o statin odagini acar, secili odaga tekrar
    /// dokunmak NoFocus'a doner; secili odak ikonu daire ile vurgulanir (CityFocus.safeValueOf(stat)).
    private func yield(_ icon: String, _ v: Double, stat: String, city: City) -> some View {
        let s = controller.state
        let focus = GameState.cityFocuses.first { $0.stat == stat }
        let selected = focus != nil && city.cityFocus == focus!.name
        let canManage = controller.isMyTurn && city.civId == s.playerId && !city.isPuppet
        return VStack(spacing: 0) {
            Text(icon).font(.system(size: 14))
                .frame(width: 24, height: 24)
                .background(Circle().stroke(selected ? Theme.gold : Color.clear, lineWidth: 1.5))
            Text(fmt(v)).font(Theme.caption.bold())
        }
        .contentShape(Rectangle())
        .onTapGesture { if let f = focus, canManage { controller.setCityFocus(selected ? "NoFocus" : f.name) } }
    }
    /// Unciv MiniStatsTable: her mini stat sayisi roundToInt ile tam sayi yazilir.
    private func fmt(_ d: Double) -> String { "\(Int(d.rounded()))" }

    private func icon(for p: Production) -> some View {
        ArtIcon(name: p.name, folder: p.isUnit ? "UnitIcons" : "BuildingIcons", fallback: p.isUnit ? "person.fill" : "building.2.fill", size: 28)
    }

    /// Unciv BuyButtonFactory.ConfirmBuyPopup: the balance, then the caution about a religious unit bought
    /// into a city of another faith, then the question. Every currency gets the same popup.
    private func buyPromptText(_ p: Production, stat: String, cost: Int, city: City) -> String {
        let s = controller.state
        var text = L("Currently you have [\(Int(reserve(stat, city: city)))] [\(stat)].") + "\n\n"
        if case .unit(let n) = p, let def = s.rs.units[n], def.uniques.contains("Religious Unit"),
           !def.uniques.contains("Takes your religion over the one in their birth city"),
           s.majorityReligion(of: city) != s.player.religionName {
            // Unciv: fun Religion?.getName() = this?.getReligionDisplayName() ?: Constants.unknownCityName ("???"),
            // and the warning is one label, so one translation key.
            let mine = s.player.religionName.map { s.religionDisplayName($0) } ?? "???"
            let majority = s.majorityReligion(of: city).map { s.religionDisplayName($0) } ?? "???"
            text += L("You are buying a religious unit in a city that doesn't follow the religion you founded ([\(mine)]). "
                      + "This means that the unit is tied to that foreign religion ([\(majority)]) and will be less useful.") + "\n"
                 + L("Are you really sure you want to purchase this unit?") + "\n\n"
        }
        // Unciv: "... for [$constructionStatBuyCost] [${stat.character}]?" — the stat's font character goes in brackets
        // (so the key is "... for [] []?"), and mapFontIcons turns it into the emoji.
        return text + L("Would you like to purchase [\(p.name)] for [\(cost)] [\(Translations.statIcons[stat] ?? stat)]?")
    }

    /// Unciv Building/BaseUnit.makeLink
    private func pediaLink(_ p: Production) -> String {
        switch p {
        case .unit(let n): return "Unit/\(n)"
        case .building(let n): return (controller.state.rs.buildings[n]?.isAnyWonder == true ? "Wonder/" : "Building/") + n
        }
    }
    /// Unciv CityConstructionsTable.addConstructionToQueue: a building no longer displayed once queued clears the selection
    private func addToQueueFromList(_ p: Production, city: City) {
        // cannotAddConstructionToQueue: a full queue, no state change allowed, a puppet, or not buildable - nothing happens
        guard canCityBeChanged(city), !controller.state.isQueueFull(city), controller.state.canProduce(p, in: city) else { return }
        // Unciv addConstructionToQueue: a CreatesOneImprovement building is queued only once its tile is picked
        if let imp = controller.state.improvementToCreate(p) {
            controller.cityPickTile = GameController.PickTileForImprovement(building: p, improvement: imp, isBuying: false, stat: "Gold")
            return
        }
        controller.cityPickTile = nil   // stopPickTileForCreatesOneImprovement
        controller.addToQueue(p)
        if case .building = p, controller.state.combinedQueue(city).contains(p) { selectedConstruction = nil }
    }

    // MARK: - Unciv CityConstructionsTable + ConstructionInfoTable + BuyButtonFactory

    /// Unciv CityScreen.canCityBeChanged: our city, our turn, not a puppet
    private func canCityBeChanged(_ city: City) -> Bool { controller.isMyTurn && city.civId == controller.state.playerId && !city.isPuppet }
    /// Unciv City.getStatReserve (gold is the treasury)
    private func reserve(_ stat: String, city: City) -> Double {
        stat == "Gold" ? controller.state.player.gold : controller.state.statPurchaseReserve(stat, in: city)
    }

    @ViewBuilder
    private func constructionsSection(_ m: CityScreenModel) -> some View {
        let city = m.city
        let canChange = canCityBeChanged(city)
        let queue = m.queue
        // Unciv getHeader("Current construction"), entry 0 or "Pick a construction", then the "Construction queue"
        SectionTitle(L("Current construction"))
        Panel(padding: 6) {
            VStack(alignment: .leading, spacing: 4) {
                if !queue.isEmpty { queueEntry(0, m: m, canChange: canChange) }
                else if !city.convertProductionTo.isEmpty { perpetualQueueEntry(city, canChange: canChange) }
                else { Text(L("Pick a construction")).font(Theme.body).foregroundStyle(Theme.creamDim).padding(.vertical, 6) }
                if queue.count > 1 {
                    Divider2()
                    Text(L("Construction queue")).font(Theme.heading(14)).foregroundStyle(Theme.gold)
                    ForEach(1..<queue.count, id: \.self) { i in queueEntry(i, m: m, canChange: canChange) }
                } else {
                    Text(L("Construction queue")).font(Theme.small).foregroundStyle(Theme.creamDim)
                }
            }
        }
        // Unciv updateAvailableConstructions: Units, Buildings, Wonders, National Wonders, Other, Disabled - a puppet has them too
        // (only isSpying hides the table); canCityBeChanged takes away its + buttons and context menus
        ForEach(m.sections, id: \.title) { section in
            SectionTitle(L(section.title))
            Panel(padding: 6) { lazyStack(alignment: .center, spacing: 0) { ForEach(section.entries, id: \.0) { e in constructionRow(e.0, rejection: e.1, m: m, canChange: canChange) } } }
        }
        let otherPerpetuals = m.otherPerpetuals
        if !otherPerpetuals.isEmpty {
            SectionTitle(L("Other"))
            Panel(padding: 6) { lazyStack(alignment: .center, spacing: 0) { ForEach(otherPerpetuals, id: \.self) { name in perpetualRow(name, m: m, canChange: canChange) } } }
        }
        let blacklisted = m.blacklisted, disabledPerpetuals = m.disabledPerpetuals
        if !blacklisted.isEmpty || !disabledPerpetuals.isEmpty {
            SectionTitle(L("Disabled"))
            Panel(padding: 6) {
                lazyStack(alignment: .center, spacing: 0) {
                    ForEach(blacklisted, id: \.0) { e in constructionRow(e.0, rejection: e.1, m: m, canChange: canChange) }
                    ForEach(disabledPerpetuals, id: \.self) { name in perpetualRow(name, m: m, canChange: canChange) }
                }
            }
        }
    }

    /// Unciv getQueueEntry: progress, portrait, name + getTurnsToConstructionString (only the first copy counts the stored
    /// progress), the resources it consumes; raise / lower / remove buttons while the city can be changed. A click selects
    /// the entry, a long press opens CityScreenConstructionMenu.
    private func queueEntry(_ index: Int, m: CityScreenModel, canChange: Bool) -> some View {
        let p = m.queue[index], info = m.queueEntry(index)
        return HStack(spacing: 8) {
            icon(for: p)
            VStack(alignment: .leading, spacing: 1) {
                Text(L(p.name)).font(Theme.body)
                if let cost = info.costLine { Text(cost).font(Theme.small).foregroundStyle(Theme.creamDim) }
                ForEach(info.consumes, id: \.self) { line in Text(line).font(Theme.small).foregroundStyle(Theme.cream) }
            }
            Spacer()
            if canChange {
                if index > 0 { Button { moveQueueEntry(index, up: true) } label: { Image(systemName: "arrow.up.circle").foregroundStyle(Theme.gold) }.buttonStyle(.plain) }
                if index != m.queue.count - 1 { Button { moveQueueEntry(index, up: false) } label: { Image(systemName: "arrow.down.circle").foregroundStyle(Theme.gold) }.buttonStyle(.plain) }
                Button { removeQueueEntry(index, city: m.city) } label: { Image(systemName: "xmark.circle").foregroundStyle(.red) }.buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(selectedQueueEntry == index ? Theme.gold.opacity(0.14) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { selectedQueueEntry = index; selectedConstruction = p }
        .onLongPressGesture(minimumDuration: UserSettings.longPressSeconds) {
            guard canChange else { return }
            selectedQueueEntry = index; selectedConstruction = p; constructionMenu = p
        }
    }
    /// A perpetual current construction (Science / Gold ... or Idle's "Nothing") is queue entry 0 too: its name and ∞. Its
    /// remove button is getRemoveFromQueueButton - removeFromQueue(0, false) leaves the emptied queue Idle; a long press
    /// opens CityScreenConstructionMenu for it while the city can be changed.
    private func perpetualQueueEntry(_ city: City, canChange: Bool) -> some View {
        let stat = city.convertProductionTo
        return HStack(spacing: 8) {
            Text(CityScreenModel.statGlyph[stat] ?? "").font(.system(size: 20)).frame(width: 28)
            Text(L(stat) + "\n∞").font(Theme.body)
            Spacer()
            if canChange { Button { controller.clearCurrentProduction(); selectedConstruction = nil; selectedQueueEntry = -1 } label: { Image(systemName: "xmark.circle").foregroundStyle(.red) }.buttonStyle(.plain) }
        }
        .padding(4)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: UserSettings.longPressSeconds) {
            guard canChange else { return }
            selectedConstruction = nil; selectedQueueEntry = -1; perpetualMenu = stat
        }
    }
    /// Unciv getConstructionButton for a PerpetualConstruction: "Produce [name]" and getProductionTooltip (the production
    /// over the conversion rate per turn; nothing for Idle), the OtherIcons/New button while cannotAddConstructionToQueue
    /// does not hold (a full queue, or this perpetual already queued); a tap queues it
    private func perpetualRow(_ name: String, m: CityScreenModel, canChange: Bool) -> some View {
        let city = m.city
        let canQueue = canChange && m.canAddPerpetual(name)
        return ThemedRow(title: L("Produce [\(name)]"), detail: m.perpetualDetail(name),
                         selected: city.currentProduction == nil && city.convertProductionTo == name,
                         // addContextMenu once canCityBeChanged: CityScreenConstructionMenu for the perpetual
                         onLongPress: canChange ? { selectedConstruction = nil; selectedQueueEntry = -1; perpetualMenu = name } : nil,
                         action: { selectedConstruction = nil; selectedQueueEntry = -1; if canChange { controller.setProductionConversion(name) } }) {
            Text(CityScreenModel.statGlyph[name] ?? "").font(.system(size: 20))
        } trailing: {
            if canQueue {
                Button { selectedConstruction = nil; selectedQueueEntry = -1; controller.setProductionConversion(name) } label: { Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.cream) }.buttonStyle(.plain)
            }
        }
    }
    /// Unciv getMovePriorityButton: the moved entry becomes the selected one
    private func moveQueueEntry(_ index: Int, up: Bool) {
        if index == 0 { if !up { controller.demoteCurrent() } }
        else if up { controller.promoteQueued(index - 1) } else { controller.demoteQueued(index - 1) }
        selectedQueueEntry = up ? index - 1 : index + 1
        if let c = controller.state.city(controller.selectedCity?.id ?? -1) {
            let q = controller.state.combinedQueue(c)
            selectedConstruction = q.indices.contains(selectedQueueEntry) ? q[selectedQueueEntry] : nil
        }
    }
    /// Unciv getRemoveFromQueueButton: after removing, the next entry (or the new last one) is selected
    private func removeQueueEntry(_ index: Int, city: City) {
        if index == 0 { controller.clearCurrentProduction() } else { controller.removeQueued(index - 1) }
        guard let c = controller.state.city(city.id) else { return }
        let q = controller.state.combinedQueue(c)
        let next = min(index, q.count - 1)
        if next >= 0 { selectedQueueEntry = next; selectedConstruction = q[next] } else { selectedQueueEntry = -1; selectedConstruction = nil }
    }

    /// Unciv getConstructionButton: portrait, name (red when rejected), turns / other-currency prices, resources, the
    /// rejection reason in red, and the OtherIcons/New button when it can be queued. First click selects, the second queues.
    private func constructionRow(_ p: Production, rejection: ConstructionRejection?, m: CityScreenModel, canChange: Bool) -> some View {
        let city = m.city
        return ThemedRow(title: L(p.name), detail: m.rowDetail(p, rejection: rejection), selected: selectedQueueEntry < 0 && selectedConstruction == p,
                         onLongPress: canChange ? { selectedQueueEntry = -1; selectedConstruction = p; constructionMenu = p } : nil,
                         titleColor: rejection == nil ? nil : .red,   // Unciv: the name in red while a rejection applies
                         // pickConstructionButton.onClick: the selected construction (a queue entry's too) is queued, another one
                         // selected; the queue selection is dropped either way
                         action: { if selectedConstruction == p { addToQueueFromList(p, city: city) } else { selectedConstruction = p }; selectedQueueEntry = -1 }) {
            icon(for: p).opacity(rejection == nil ? 1 : 0.5)
        } trailing: {
            if m.canAddToQueue(p) && canChange {
                Button { selectedQueueEntry = -1; selectedConstruction = p; addToQueueFromList(p, city: city) } label: { Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.cream) }.buttonStyle(.plain)
            }
        }
    }

    /// Unciv ConstructionInfoTable + BuyButtonFactory.getBuyButtons
    private func selectedPanel(_ sel: Production, m: CityScreenModel, canChange: Bool) -> some View {
        let city = m.city, s = controller.state, info = m.selected(sel)
        return Panel(padding: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button { controller.civilopediaEntry = pediaLink(sel); controller.showCivilopedia = true } label: { icon(for: sel) }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L(sel.name)).font(Theme.heading(15)).foregroundStyle(Theme.gold)
                        if let cost = info.costLine { Text(cost).font(Theme.caption).foregroundStyle(Theme.cream) }
                    }
                    Spacer()
                }
                Text(info.description).font(Theme.caption).foregroundStyle(Theme.cream).fixedSize(horizontal: false, vertical: true)
                if case .building(let b) = sel, city.buildings.contains(b) {
                    // ConstructionInfoTable.showSellButton: "{Sell} N ¤" for a sellable building, enabled when it is not free,
                    // not in a puppet, the city can be changed and nothing was sold this turn (god mode ignores that)
                    if let sell = info.sell {
                        Button(sell.text) { Audio.shared.play("coin"); sellCandidate = b }
                            .buttonStyle(ThemedButtonStyle(compact: true)).disabled(!(sell.enabled && canChange))
                    }
                }
                // ConstructionInfoTable: the buy buttons for a puppet too - isConstructionPurchaseAllowed disables them there
                // ("allow puppets, since isConstructionPurchaseAllowed handles that")
                else {
                    HStack(spacing: 8) { ForEach(info.buy, id: \.stat) { b in buyButton(sel, b, city: city, s: s) } }
                }
                // BuyButtonFactory: the priced buy buttons' tooltip when isConstructionPurchaseBlockedByUnit
                if info.blockedByUnit {
                    Text(L("Move unit out of city first")).font(Theme.small).foregroundStyle(Theme.danger)
                }
                if case .unit(let un) = sel, info.useDefaultPromotions != nil {
                    Toggle(L("Use default promotions"), isOn: Binding(get: { city.useDefaultPromotions.contains(un) }, set: { controller.setCityUseDefaultPromotions(un, $0) }))
                        .font(Theme.small).tint(Theme.gold).disabled(!canChange)
                }
            }
        }
    }

    /// Unciv BuyButtonFactory.getBuyButton: shown when it can be bought with the stat ("Buy cost glyph"); a lone disabled
    /// "Buy" when nothing can buy it at all; enabled by canChangeState && isConstructionPurchaseAllowed (reserve included).
    @ViewBuilder
    private func buyButton(_ p: Production, _ b: CityScreenModel.BuyButton, city: City, s: GameState) -> some View {
        if let cost = b.cost {
            let enabled = controller.isMyTurn && city.civId == s.playerId && b.allowed
            Button("\(L("Buy")) \(cost)\(CityScreenModel.statGlyph[b.stat] ?? "")") {
                // Unciv BuyButtonFactory.buyButtonOnClick: a CreatesOneImprovement building picked from the list asks for its tile first
                if let imp = s.improvementToCreate(p), selectedQueueEntry < 0 {
                    controller.cityPickTile = GameController.PickTileForImprovement(building: p, improvement: imp, isBuying: true, stat: b.stat)
                    return
                }
                purchasePrompt = PurchasePrompt(text: buyPromptText(p, stat: b.stat, cost: cost, city: city), action: { purchase(p, stat: b.stat, city: city) })
            }
            .buttonStyle(ThemedButtonStyle(filled: true, compact: true))
            .disabled(!enabled)
        } else {
            Button(L("Buy")) {}.buttonStyle(ThemedButtonStyle(compact: true)).disabled(true)
        }
    }

    /// Unciv BuyButtonFactory.purchaseConstruction: the selected queue entry is bought out of the queue; a failed placement
    /// shows "No space available…"; afterwards a queue selection, or a selection no longer buildable, gives way to the
    /// new current construction.
    /// Unciv CityScreen.tileGroupOnClick while picking: an acceptable tile queues the building with it, or asks to buy it there
    private func pickedTile(_ tile: HexCoord, city: City) {
        guard let pick = controller.cityPickTile else { return }
        controller.cityPickTile = nil
        let s = controller.state
        guard let c = s.city(city.id), s.canPlaceCreateOneImprovementOn(pick.improvement, tile, city: c) else { return }
        if pick.isBuying {
            guard let cost = s.getStatBuyCost(pick.building, city: c, stat: pick.stat) else { return }
            purchasePrompt = PurchasePrompt(text: buyPromptText(pick.building, stat: pick.stat, cost: cost, city: c), action: { purchase(pick.building, stat: pick.stat, city: c, tile: tile) })
        } else {
            controller.addToQueueWithTile(pick.building, tile: tile)
        }
    }
    private func purchase(_ p: Production, stat: String, city: City, tile: HexCoord? = nil) {
        let ok = controller.purchaseConstruction(p, stat: stat, queuePosition: selectedQueueEntry >= 0 ? selectedQueueEntry : nil, tile: tile)
        guard ok else { noSpaceText = L("No space available to place [\(p.name)] near [\(city.name)]"); return }
        let s = controller.state
        guard let c = s.city(city.id) else { return }
        let stillBuildable = selectedConstruction.map { sc -> Bool in
            switch sc {
            case .unit(let n): return s.rs.units[n].map { s.unitRejections($0, city: c).isEmpty } ?? false
            case .building(let n): return s.rs.buildings[n].map { s.buildingRejections($0, city: c).isEmpty } ?? false
            }
        } ?? false
        if selectedQueueEntry >= 0 || !stillBuildable {
            selectedQueueEntry = -1
            selectedConstruction = c.currentProduction
        }
    }
}

struct TechScreen: View {
    @ObservedObject var controller: GameController
    @State private var selectedTech: String? = nil   // Unciv TechPickerScreen.selectedTech
    @State private var tempTechsToResearch: [String] = []   // Unciv tempTechsToResearch
    @State private var freeTechPick = false   // Unciv: fixed when the picker opens
    @State private var buttonText = ""
    @State private var buttonEnabled = false
    @State private var opened = false
    var body: some View {
        let _ = UIMeasure.count("TechScreen.body")
        let s = controller.state
        let civ = controller.selectedCiv   // Unciv TechPickerScreen(worldScreen.selectedCiv) from the top bar's science
        let science = s.scienceForNextTurn(civ.id)   // Unciv TechManager.turnsToTech: civInfo.stats.statsForNextTurn.science
        // TechPickerScreen has no era / count / science summary
        ThemedSheet(freeTechPick ? L("Pick a free tech") : L("Pick a tech"), subtitle: nil, scrolls: false, onClose: { controller.showTech = false }) {
            // Unciv PickerPane: the tree's scrollPane takes the screen and centres on the technology (centerOnTechnology),
            // the bottomTable under it holds the description (at most maxBottomTableHeight, scrolling) and the right-side button
            TechTreeView(controller: controller, selectedTech: selectedTech, tempTechsToResearch: tempTechsToResearch,
                         onSelect: { selectTechnology($0, queue: false) }, onQueue: { selectTechnology($0, queue: true) }, onConfirm: { tryExit() })   // Unciv: `techButton.onDoubleClick(UncivSound.Paper) { tryExit() }`, whatever the right-side button says
            Spacer(minLength: 0)   // the bottomTable stays at the bottom when the tree is shorter than the room
            Panel(padding: 8) {
                HStack(alignment: .bottom, spacing: 10) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            if let name = selectedTech, let t = s.rs.techs[name] {
                                HStack { ArtIcon(name: t.name, folder: "TechIcons", fallback: "book.fill", size: 28); Text(L(t.name)).font(Theme.heading(15)).foregroundStyle(Theme.gold); Spacer(); Text(L(t.era)).font(Theme.small).foregroundStyle(Theme.creamDim) }
                                // Unciv TechPickerScreen.descriptionLabel: tech.getDescription(civInfo)
                                Text(ObjectDescriptions.techDescription(t, civId: civ.id, s: s)).font(Theme.small).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 100)   // Unciv maxBottomTableHeight 150 on its stage, about 7 lines (here 6, on the virtual canvas); one height whatever is selected, so the tree keeps the box it was centred in
                    Button(buttonText) { tryExit() }.buttonStyle(ThemedButtonStyle(filled: buttonEnabled, compact: true, multiline: true)).disabled(!buttonEnabled)
                }
            }
        }
        .onAppear {
            guard !opened else { return }
            opened = true
            freeTechPick = civ.freeTechs > 0
            tempTechsToResearch = (civ.currentTech.map { [$0] } ?? []) + civ.techQueue
            buttonText = freeTechPick ? L("Pick a free tech") : L("Pick a tech")
            buttonEnabled = false
            // Unciv: show the notified or current technology, selecting it when that does not disturb the queue
            let center = controller.techPickerCenterOn ?? civ.currentTech
            controller.techPickerCenterOn = nil
            if let t = center, civ.techs.contains(t) || tempTechsToResearch.count <= 1 { selectTechnology(t, queue: false) }
            else if let t = center { selectedTech = nil; _ = t }
        }
        .screenShown("tech_tree")
    }

}

extension TechScreen {
    /// Units, buildings (wonders included) and improvements the technology unlocks
    func techUnlocks(_ t: TechDef) -> [String] {
        let s = controller.state
        // Unciv TechnologyDescriptions.getEnabledUnits: the list belongs to the viewing civ - its own unique unit
        // in place of the base one it replaces, and no other nation's uniques at all.
        let nation = controller.selectedCiv.nation
        func mine(_ uniqueTo: String?) -> Bool { uniqueTo == nil || uniqueTo == nation }
        let units = s.rs.units.values.filter { $0.requiredTech == t.name && mine($0.uniqueTo) }
            .filter { u in u.uniqueTo != nil || !s.rs.units.values.contains { $0.uniqueTo == nation && $0.replaces == u.name } }
        let buildings = s.rs.buildings.values.filter { $0.requiredTech == t.name && mine($0.uniqueTo) }
            .filter { b in b.uniqueTo != nil || !s.rs.buildings.values.contains { $0.uniqueTo == nation && $0.replaces == b.name } }
        // Unciv TechnologyDescriptions: a technology also says which resource it puts on the map.
        let revealed = s.rs.resources.values.filter { $0.revealedBy == t.name }.map { L("Reveals [\($0.name)] on the map") }
        return (units.map { $0.name } + buildings.map { $0.name }
                + s.rs.improvements.values.filter { $0.techRequired == t.name && mine($0.uniqueTo) }.map { $0.name }).sorted() + revealed.sorted()
    }
    /// Unciv TechPickerScreen.getTechProgressLabel (overflow science included)
    func techProgressLabel(_ techs: [String], civ: Civilization) -> String {
        let s = controller.state
        let progress = techs.reduce(0) { $0 + s.researchOfTech(civ, $1) } + civ.overflowScience
        let cost = techs.reduce(0.0) { acc, n in acc + (s.rs.techs[n].map { s.techCost($0, for: civ) } ?? 0) }
        return "(\(progress)/\(Int(cost)))"
    }
    /// Unciv TechPickerScreen.selectTechnology / selectTechnologyForFreeTech
    func selectTechnology(_ name: String, queue: Bool) {
        let s = controller.state
        let civ = controller.selectedCiv
        guard let tech = s.rs.techs[name] else { return }
        let previousSelectedTech = selectedTech
        selectedTech = name
        if freeTechPick {
            if s.researchableTechs(for: civ).contains(where: { $0.name == name }) {
                buttonText = L("Pick [\(name)] as free tech") + "\n" + techProgressLabel([name], civ: civ); buttonEnabled = true
            } else { buttonText = L("Pick a free tech"); buttonEnabled = false }
            return
        }
        if s.settings.godMode && !civ.techs.contains(name) && name == previousSelectedTech { controller.godModeAddTech(name) }
        let civNow = controller.selectedCiv
        if civNow.techs.contains(name) && !tech.uniques.contains("Can be continually researched") {
            buttonText = L("Pick a tech"); buttonEnabled = false; return
        }
        // Unciv `if (!GUI.isAllowedChangeState())`: worldScreen.canChangeState - our turn, and no spectator
        if !controller.isMyTurn || controller.player.isSpectator { buttonEnabled = false; return }
        let pathToTech = s.requiredTechsToDestination(civNow, name)
        for required in pathToTech {
            if let u = s.unavailableUnique(civNow, required) {
                buttonText = L(u.text); buttonEnabled = false; return
            }
        }
        if queue {
            for t in pathToTech where !tempTechsToResearch.contains(t.name) { tempTechsToResearch.append(t.name) }
        } else {
            tempTechsToResearch = pathToTech.map { $0.name }
        }
        if let first = tempTechsToResearch.first {
            buttonText = L("Research [\(first)]") + "\n" + techProgressLabel(tempTechsToResearch, civ: civNow); buttonEnabled = true
        } else { buttonText = L("Unavailable"); buttonEnabled = false }
    }
    /// Unciv TechPickerScreen.tryExit. The paper sound belongs to the click that calls it (rightSideButton.onClick and
    /// techButton.onDoubleClick both carry UncivSound.Paper), so it plays even when a free pick is refused.
    func tryExit() {
        Audio.shared.play("paper")
        controller.confirmTechPicker(freeTech: freeTechPick ? selectedTech : nil, queue: tempTechsToResearch)
    }
}

/// The city screen's own popups (rename, detailed stats, GPP breakdown, sell dialog) and the era ambience.
private struct CityScreenPopups: ViewModifier {
    @ObservedObject var controller: GameController
    let city: City
    @Binding var sellCandidate: String?
    var onSold: () -> Void = {}   // sellBuildingConfirmed: cityScreen.clearSelection()
    let era: EraDef?
    func body(content: Content) -> some View {
        let s = controller.state
        return content
            .overlay { if controller.showRenameCity { RenamePopup(title: L("Please enter a new name for your city"), initial: city.name, onDone: { n in if let n { controller.renameCity(n) }; controller.showRenameCity = false }) } }
            .sheet(isPresented: $controller.showDetailedStats) { DetailedStatsPopup(controller: controller, cityId: city.id).immersiveSystemUI() }
            .overlay { if controller.showGPPBreakdown { GreatPersonPointsBreakdownPopup(controller: controller, cityId: city.id) } }
            .onAppear { Audio.shared.startCityAmbience(era: era) }
            .onDisappear { Audio.shared.stopCityAmbience() }
            .confirmationDialog(L("Are you sure you want to sell this [\(sellCandidate ?? "")]?"), isPresented: Binding(get: { sellCandidate != nil }, set: { if !$0 { sellCandidate = nil } }), titleVisibility: .visible) {
                if let b = sellCandidate { Button(L("Sell") + " \(s.goldForSellingBuilding(b)) 💰", role: .destructive) { controller.sellBuilding(b); sellCandidate = nil; onSold() } }
                Button(L("Cancel"), role: .cancel) { sellCandidate = nil }
            }
    }
}

/// Unciv LeaderIntroTable: leader portrait (LeaderPortraits/<leader>, when the art exists) or the nation icon, "Leader of Nation" and the greeting.
struct LeaderIntroView: View {
    let civ: Civilization
    /// Unciv Nation.getLeaderDisplayName(title): "[leader] of [nation]", or "[title filled with the leader] of [nation]"
    static func displayName(_ civ: Civilization) -> String {
        if civ.isCityState || civ.isSpectator { return civ.nation }   // Nation.getLeaderDisplayName: a city-state is just its name
        guard let t = civ.leaderTitle, !t.isEmpty else { return "[\(civ.leaderName)] of [\(civ.nation)]" }
        let filled = Translations.placeholderParameters(t).first.map { t.replacingOccurrences(of: "[\($0)]", with: "[\(civ.leaderName)]") } ?? t
        return "[\(filled)] of [\(civ.nation)]"
    }
    var hello: String? = nil
    /// Civilization.getLeaderDisplayName: " (AI)" / " (Human - Hotseat)" / " (Human - Multiplayer)" once the game has
    /// several humans or is online
    var suffix: String = ""
    static func suffix(_ civ: Civilization, _ s: GameState) -> String {
        let severalHumans = s.civs.filter { $0.isPlayer }.count > 1
        let online = s.settings.isOnline
        if !online && !severalHumans { return "" }
        if !civ.isPlayer { return " (\(L("AI")))" }
        return online ? " (\(L("Human")) - \(L("Multiplayer")))" : " (\(L("Human")) - \(L("Hotseat")))"
    }
    var body: some View {
        let leader = civ.nationDef?.leaderName ?? ""
        HStack(spacing: 10) {
            if !leader.isEmpty, let img = Art.shared.image(leader, folder: "LeaderPortraits") {
                Image(uiImage: img).resizable().scaledToFit().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) { Text(L(LeaderIntroView.displayName(civ)) + suffix).font(Theme.heading(15)); NationBadge(nation: civ.nationDef, size: 20) }
                    if let h = hello, !h.isEmpty { Text(L(h)).font(Theme.small).foregroundStyle(Theme.creamDim).italic() }
                }
            } else {
                NationBadge(nation: civ.nationDef, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(LeaderIntroView.displayName(civ)) + suffix).font(Theme.heading(15))
                    if let h = hello, !h.isEmpty { Text(L(h)).font(Theme.small).foregroundStyle(Theme.creamDim).italic() }
                }
            }
        }
    }
}

/// Unciv CityScreenConstructionMenu: queue reordering, empire-wide queueing and disabling a construction.
struct ConstructionMenuView: View {
    @ObservedObject var controller: GameController
    let city: City
    let production: Production
    let onClose: () -> Void
    @State private var shown = false   // Unciv AnimatedMenuPopup: fade and scale in / out over 0.33s
    private func animatedClose() {
        withAnimation(.easeInOut(duration: 0.33)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.33) { onClose() }
    }
    var body: some View {
        let s = controller.state
        let name = production.name
        // Unciv CityScreenConstructionMenu: myIndex in the queue (the current construction is entry 0)
        let combined = s.combinedQueue(city)
        let myIndex = combined.firstIndex(of: production) ?? -1
        // isConstructionImprovementCreationBuilding: Building.hasCreateOneImprovementUnique
        let createsImprovement: Bool = { if case .building(let b) = production { return s.rs.buildings[b]?.uniqueObjects.contains { $0.pattern == "Creates a [] improvement on a specific tile" } ?? false }; return false }()
        // candidateCities / allCitiesEntryValid: more than one city, not a wonder, and some non-puppet city not in
        // resistance or being razed where the predicate holds
        let candidates = s.cities(of: city.civId).filter { !$0.isPuppet && $0.resistanceTurns == 0 && !$0.razing }
        let allCitiesEntryValid: ((City) -> Bool) -> Bool = { predicate in
            s.cities(of: city.civId).count > 1 && !(s.rs.buildings[name]?.isAnyWonder ?? false) && candidates.contains(where: predicate)
        }
        let canAddAll = allCitiesEntryValid { s.canAddToQueue(production, in: $0) && !createsImprovement }
        let canAddAllTop = allCitiesEntryValid { (s.canAddToQueue(production, in: $0) && !createsImprovement) || (s.combinedQueue($0).firstIndex(of: production) ?? 0) > 0 }
        let canRemoveAll = allCitiesEntryValid { s.combinedQueue($0).contains(production) }
        ZStack {
            Color.black.opacity(shown ? 0.35 : 0).ignoresSafeArea().bleedIntoCutout().onTapGesture { guard !UserSettings.neverCloseByTapOutside else { return }; animatedClose() }
            Panel() {
                VStack(alignment: .leading, spacing: 6) {
                    if myIndex > 0 { item(L("Move to the top of the queue")) { controller.queueAction { $0.moveQueueEntryToTop(cityId: city.id, index: myIndex) } } }
                    if myIndex >= 0 && myIndex < combined.count - 1 { item(L("Move to the end of the queue")) { controller.queueAction { $0.moveQueueEntryToEnd(cityId: city.id, index: myIndex) } } }
                    if s.canAddToQueue(production, in: city) && !createsImprovement { item(L("Add to the top of the queue")) { controller.queueAction { $0.addToQueueTop(cityId: city.id, production) } } }
                    if canAddAll { item(L("Add to the queue in all cities")) { controller.queueAction { $0.addToAllQueues(production, civId: city.civId) } } }
                    if canAddAllTop { item(L("Add or move to the top in all cities")) { controller.queueAction { $0.addOrMoveToTopInAllCities(production, civId: city.civId) } } }
                    if canRemoveAll { item(L("Remove from the queue in all cities")) { controller.queueAction { $0.removeFromAllQueues(production, civId: city.civId) } } }
                    if !city.disabledConstructions.contains(name) { item(L("Disable in this city")) { controller.setConstructionDisabled(name, cityWide: false, true) } }
                    if !s.player.disabledCivConstructions.contains(name) { item(L("Disable in all cities")) { controller.setConstructionDisabled(name, cityWide: true, true) } }
                    if city.disabledConstructions.contains(name) { item(L("Enable in this city")) { controller.setConstructionDisabled(name, cityWide: false, false) } }
                    if s.player.disabledCivConstructions.contains(name) { item(L("Enable in all cities")) { controller.setConstructionDisabled(name, cityWide: true, false) } }
                    // AnimatedMenuPopup closes by a tap behind it; with "never close by tapping outside" that way is gone
                    if UserSettings.neverCloseByTapOutside { Button(L("Close")) { animatedClose() }.buttonStyle(ThemedButtonStyle(compact: true)) }
                }
            }.frame(maxWidth: 380)
            .scaleEffect(shown ? 1 : 0.01).opacity(shown ? 1 : 0)
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.33)) { shown = true } }
    }
    private func item(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title) { action(); animatedClose() }.buttonStyle(ThemedButtonStyle(compact: true))
    }
}

/// Unciv CityScreenConstructionMenu for a PerpetualConstruction (a stat conversion or Idle's "Nothing", ours kept in
/// convertProductionTo): no moving and no adding to the top; "Add to the queue in all cities" where it can be added and is
/// not queued yet, "Remove from the queue in all cities" where it is queued, and disabling / enabling it - never Idle.
/// Like Unciv's popup (createContentTable returns null), it does not open without an entry.
struct PerpetualConstructionMenuView: View {
    @ObservedObject var controller: GameController
    let city: City
    let name: String
    let onClose: () -> Void
    @State private var shown = false   // Unciv AnimatedMenuPopup: fade and scale in / out over 0.33s
    private func animatedClose() {
        withAnimation(.easeInOut(duration: 0.33)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.33) { onClose() }
    }
    var body: some View {
        let s = controller.state
        let isIdle = name == City.idleConstruction
        // candidateCities / allCitiesEntryValid: more than one city, and some non-puppet city not in resistance or being razed
        let candidates = s.cities(of: city.civId).filter { !$0.isPuppet && $0.resistanceTurns == 0 && !$0.razing }
        let allCitiesEntryValid: ((City) -> Bool) -> Bool = { predicate in s.cities(of: city.civId).count > 1 && candidates.contains(where: predicate) }
        // canAddAllQueues: canAddToQueue, but a perpetual already queued there does not count
        let canAddAll = allCitiesEntryValid { s.canAddPerpetualToQueue(name, in: $0) && $0.convertProductionTo != name }
        let canRemoveAll = allCitiesEntryValid { $0.convertProductionTo == name }   // isBeingConstructedOrEnqueued
        let canDisable = !city.disabledConstructions.contains(name) && !isIdle
        let canDisableAll = !s.player.disabledCivConstructions.contains(name) && !isIdle
        let canEnable = city.disabledConstructions.contains(name)
        let canEnableAll = s.player.disabledCivConstructions.contains(name)
        if !(canAddAll || canRemoveAll || canDisable || canDisableAll || canEnable || canEnableAll) {
            Color.clear.onAppear { onClose() }
        } else {
            ZStack {
                Color.black.opacity(shown ? 0.35 : 0).ignoresSafeArea().bleedIntoCutout().onTapGesture { guard !UserSettings.neverCloseByTapOutside else { return }; animatedClose() }
                Panel() {
                    VStack(alignment: .leading, spacing: 6) {
                        if canAddAll { item(L("Add to the queue in all cities")) { controller.queueAction { $0.addPerpetualToAllQueues(name, civId: city.civId) } } }
                        if canRemoveAll { item(L("Remove from the queue in all cities")) { controller.queueAction { $0.removePerpetualFromAllQueues(name, civId: city.civId) } } }
                        if canDisable { item(L("Disable in this city")) { controller.setConstructionDisabled(name, cityWide: false, true) } }
                        if canDisableAll { item(L("Disable in all cities")) { controller.setConstructionDisabled(name, cityWide: true, true) } }
                        if canEnable { item(L("Enable in this city")) { controller.setConstructionDisabled(name, cityWide: false, false) } }
                        if canEnableAll { item(L("Enable in all cities")) { controller.setConstructionDisabled(name, cityWide: true, false) } }
                        if UserSettings.neverCloseByTapOutside { Button(L("Close")) { animatedClose() }.buttonStyle(ThemedButtonStyle(compact: true)) }
                    }
                }.frame(maxWidth: 380)
                .scaleEffect(shown ? 1 : 0.01).opacity(shown ? 1 : 0)
            }
            .onAppear { withAnimation(.easeInOut(duration: 0.33)) { shown = true } }
        }
    }
    private func item(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title) { action(); animatedClose() }.buttonStyle(ThemedButtonStyle(compact: true))
    }
}

extension GameState {
    /// Unciv Stat.character for the currencies a construction can be bought with
    static let buyStatGlyph = ["Gold": "💰", "Food": "🍎", "Science": "🔬", "Culture": "🎵", "Faith": "🕊"]

    /// Unciv getTurnsToConstructionString's `buildable`, negated: an Unbuildable unique whose conditionals hold in the city
    func isUnbuildable(_ p: Production, city: City) -> Bool {
        let uniques: [Unique]
        switch p {
        case .unit(let n): uniques = rs.units[n]?.uniqueObjects ?? []
        case .building(let n): uniques = rs.buildings[n]?.uniqueObjects ?? []
        }
        return uniques.contains { $0.pattern == "Unbuildable" && conditionalsHold($0, UniqueContext(civId: city.civId, city: city)) }
    }

    /// Unciv CityConstructionsView.getTurnsToConstructionString (ui/components/extensions/ViewExtensions.kt), as lines: the
    /// "[progress/]cost⚙ turns⏳" line unless the construction is Unbuildable, then its prices in every Stat.entries
    /// currency it canBePurchasedWithStat - Gold only when it cannot be built ("Don't show rush cost for consistency").
    func turnsToConstructionLines(_ p: Production, in city: City, useStored: Bool = true) -> [String] {
        let buildable = !isUnbuildable(p, city: city)
        var lines: [String] = []
        if buildable {
            let done = useStored ? workDone(p, in: city) : 0
            lines.append((done == 0 ? "" : "\(done)/") + "\(productionCost(p, for: city.civId))⚙️ \(turnsToConstruction(p, in: city, useStored: useStored) ?? 0)⏳")
        }
        // Stat.entries order; Production and Happiness are never purchasable (canBePurchasedWithStatReasons: Invalid)
        let others = ["Food", "Gold", "Science", "Culture", "Faith"]
            .filter { ($0 != "Gold" || !buildable) && canBePurchasedWithStat(p, city: city, stat: $0) }
            .compactMap { st in getStatBuyCost(p, city: city, stat: st).map { "\($0)\(Self.buyStatGlyph[st] ?? "")" } }
        if !others.isEmpty { lines.append(others.joined(separator: " / ")) }
        return lines
    }

    /// `lines.joinToString("\n", "\n")`: every line after a line break (a lone "\n" when there is none)
    func turnsToConstructionString(_ p: Production, in city: City, useStored: Bool = true) -> String {
        "\n" + turnsToConstructionLines(p, in: city, useStored: useStored).joined(separator: "\n")
    }
}
