// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv GreatPersonPickerScreen: every great person of the civ, those it may take now enabled; a tap picks one ("Get [x]") and
/// shows its short description (a link to its Civilopedia page), a double tap or the button takes it with Choir. There is no
/// close button until the choice turns out impossible (allowClose).
struct GreatPersonPickerScreen: View {
    @ObservedObject var controller: GameController
    @State private var chosen: String? = nil          // Unciv theChosenOne
    @State private var description: String? = nil    // Unciv descriptionLabel
    @State private var canClose = false               // Unciv allowClose
    var body: some View {
        let s = controller.state
        let options = Set(s.freeGreatPersonOptions(s.playerId).map { $0.name })
        let closable = canClose || options.isEmpty
        ReligionPickerFrame(onClose: { controller.deferFreeGreatPersonPicker = true; controller.showGreatPersonPicker = false },
                            showClose: closable,
                            okTitle: chosen.map { L("Get [\($0)]") } ?? L("Choose a free great person"),
                            okEnabled: chosen != nil,
                            onOK: confirm) {
            EmptyView()
        } content: {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(s.greatPeopleUnits(s.playerId)) { gp in
                        let enabled = options.contains(gp.name)
                        HStack(spacing: 10) {
                            ArtIcon(name: gp.name, folder: "UnitIcons", fallback: "person.fill", size: 36)
                            Text(L(gp.name)).font(Theme.heading(15))
                            Spacer(minLength: 0)
                        }
                        .padding(10).frame(maxWidth: 360)
                        .background(RoundedRectangle(cornerRadius: 10).fill(chosen == gp.name ? Theme.gold.opacity(0.18) : Theme.fill))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(chosen == gp.name ? Theme.gold : Theme.hairline, lineWidth: chosen == gp.name ? 1.5 : 1))
                        .opacity(enabled ? 1 : 0.4)
                        .contentShape(Rectangle())
                        .uncivTaps(onTap: { if enabled { pick(gp) } }, onDoubleTap: { if enabled { pick(gp); confirm() } })
                    }
                }
                .frame(maxWidth: .infinity).padding(.top, 54).padding(.bottom, 10)
            }
        } description: {
            if let d = description ?? (options.isEmpty ? L("Unavailable") : nil) {
                Button {
                    if let c = chosen { controller.showGreatPersonPicker = false; controller.afterSheetDismiss { controller.civilopediaEntry = "Unit/\(c)"; controller.showCivilopedia = true } }
                } label: { Text(d).font(Theme.caption).foregroundStyle(Theme.cream).multilineTextAlignment(.leading) }.buttonStyle(.plain)
            }
        }
        // Unciv GreatPersonPickerScreen init: worldScreen.autoPlay.stopAutoPlay()
        .onAppear { controller.stopAutoPlay() }
    }

    private func pick(_ gp: UnitDef) {
        chosen = gp.name
        description = ObjectDescriptions.unitShortDescription(gp)
    }

    /// Unciv confirmAction: the choice is checked again; unavailable or without room it stays open and may be closed
    private func confirm() {
        guard let name = chosen else { return }
        Audio.shared.play("choir")
        let s = controller.state
        let current = s.freeGreatPersonOptions(s.playerId)
        if !current.contains(where: { $0.name == name }) {
            description = L("Unavailable")
            if current.isEmpty { controller.showGreatPersonPicker = false }
            else { chosen = nil; canClose = true }
            return
        }
        if !controller.chooseFreeGreatPerson(name) {
            description = L("No space to place this unit")
            canClose = true
            return
        }
        controller.deferFreeGreatPersonPicker = false
        controller.showGreatPersonPicker = false
    }
}

/// Unciv MayaCalendar.openPopup: explains the Long Count year shown on the world screen.
struct MayaCalendarPopup: View {
    @ObservedObject var controller: GameController
    var body: some View {
        let s = controller.state
        let y = s.year
        let parts = GameState.mayaParts(year: y)
        let outer = s.player.nationDef?.outerColor ?? [212, 175, 55]
        ThemedDialog(title: L("The Mayan Long Count"), onDismiss: { controller.showMayaCalendar = false }) {
            Rectangle().fill(Color(red: Double(outer[0]) / 255, green: Double(outer[1]) / 255, blue: Double(outer[2]) / 255)).frame(height: 2)
            Text(L("Your scientists and theologians have devised a systematic approach to measuring long time spans - the Long Count. During the festivities whenever the current b'ak'tun ends, a Great Person will join you.")).font(Theme.body).fixedSize(horizontal: false, vertical: true)
            let yearText = GameState.yearText(year: y, usesMayaCalendar: false)
            Text(L("While the rest of the world calls the current year [\(yearText)], in the Maya Calendar that is:")).font(Theme.body).fixedSize(horizontal: false, vertical: true)
            Text(GameState.mayaDate(year: y)).font(.system(size: 42, weight: .bold, design: .serif)).foregroundStyle(Theme.gold).frame(maxWidth: .infinity)
            Text(L("[\(parts.baktuns)] b'ak'tun, [\(parts.katuns)] k'atun, [\(parts.tuns)] tun")).font(Theme.body).frame(maxWidth: .infinity)
            Button(L("Close")) { controller.showMayaCalendar = false }.buttonStyle(ThemedButtonStyle(compact: true))
        }
    }
}
