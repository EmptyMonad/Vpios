// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv LanguagePickerScreen: shown once on the first launch — every language of the completion table in LanguageTable order,
/// the system language preselected (chosenLanguage = LocaleCode.getSystemLanguage()); with no supported system language nothing is
/// selected and "Pick language" stays disabled until a row is tapped (rightSideButton is only enabled by onChoice).
struct LanguagePickerScreen: View {
    let onDone: () -> Void
    @State private var chosen: String = L10n.systemLanguage ?? ""

    static var shouldShow: Bool { !UserDefaults.standard.bool(forKey: "epochs.languagePicked") && L10n.override == nil }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea().bleedIntoCutout()
            VStack(spacing: 10) {
                // Unciv LanguagePickerScreen is a PickerScreen with no title over the language tables
                LanguageDisclaimer().padding(.horizontal, 20).padding(.top, 12)   // Unciv LanguageTable translationDisclaimer
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(L10n.languageTables(), id: \.language) { row in
                            let lang = row.language
                            Button { chosen = lang } label: {
                                HStack {
                                    Image(systemName: chosen == lang ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.gold)
                                    // LanguageTable: "$spaceSplitLang ($percentComplete%)".toLabel() - one label through tr()
                                    Text(L("\(lang.replacingOccurrences(of: "_", with: " ")) (\(row.percent)%)")).font(Theme.body)
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(chosen == lang ? Theme.panelLight : Theme.panelDark))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 20)
                }
                Button(L("Pick language")) {
                    L10n.override = chosen
                    GameEvents.post(.languageChanged(chosen, source: "first_launch"))
                    UserDefaults.standard.set(true, forKey: "epochs.languagePicked")
                    onDone()
                }.buttonStyle(ThemedButtonStyle(filled: true)).disabled(chosen.isEmpty).padding(.bottom, 12)
            }
        }
        .foregroundStyle(Theme.cream)
    }
}

/// Unciv LoadingScreen / LoadingPopup: the previous screen stays visible; after a second a "Loading..." popup appears on top.
struct LoadingOverlay: View {
    let active: Bool
    @State private var visible = false
    var body: some View {
        ZStack {
            if active && visible {
                Color.black.opacity(0.35).ignoresSafeArea().bleedIntoCutout()
                Panel(highlighted: true) { HStack(spacing: 10) { ProgressView().tint(Theme.gold); Text(L("Loading...")).font(Theme.heading(15)).foregroundStyle(Theme.gold) } }
            }
        }
        .allowsHitTesting(active)
        .onChange(of: active) { _, on in
            if on { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { if active { visible = true } } } else { visible = false }
        }
    }
}

/// Unciv LanguageTable.addLanguageTables: the translation disclaimer, linking to the Unciv translating wiki page.
struct LanguageDisclaimer: View {
    var body: some View {
        Link(destination: URL(string: "https://yairm210.github.io/Unciv/Translating/Translating/")!) {
            Text(L("Please note that translations are a community-based work in progress and are INCOMPLETE! The percentage shown is how much of the language is translated in-game. If you want to help translating the game into your language, click here.")).font(Theme.small).foregroundStyle(Theme.creamDim).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
        }
    }
}
