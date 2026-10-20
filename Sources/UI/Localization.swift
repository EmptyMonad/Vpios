// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Tiny localisation layer: English keys, Turkish translations. Language follows the device unless overridden in settings.
enum L10n {
    /// Unciv language name ("Turkish", "English", …) or "auto" (follow the device).
    static var override: String? {
        get {
            let v = UserDefaults.standard.string(forKey: "epochs.language")
            switch v { case "tr": return "Turkish"; case "en": return "English"; default: return v }
        }
        set { UserDefaults.standard.set(newValue, forKey: "epochs.language"); reload() }
    }
    /// ISO language codes → Unciv translation file names.
    static let isoToUnciv: [String: String] = [
        "tr": "Turkish", "en": "English", "de": "German", "fr": "French", "es": "Spanish", "it": "Italian", "ru": "Russian", "ja": "Japanese", "ko": "Korean",
        "zh-Hans": "Simplified_Chinese", "zh-Hant": "Traditional_Chinese", "zh": "Simplified_Chinese", "pt-BR": "Brazilian_Portuguese", "pt": "Portuguese", "nl": "Dutch", "pl": "Polish",
        "uk": "Ukrainian", "cs": "Czech", "hu": "Hungarian", "id": "Indonesian", "sv": "Swedish", "fi": "Finnish", "nb": "Norwegian", "no": "Norwegian", "ro": "Romanian", "el": "Greek",
        "bg": "Bulgarian", "hr": "Croatian", "ca": "Catalan", "gl": "Galician", "vi": "Vietnamese", "th": "Thai", "ms": "Malay", "hi": "Hindi", "bn": "Bangla", "fa": "Persian_(Pinglish-UN)",
        "lt": "Lithuanian", "af": "Afrikaans", "zu": "Zulu", "be": "Belarusian", "bs": "Bosnian", "mt": "Maltese", "la": "Latin", "eo": "Esperanto", "fil": "Filipino", "nv": "Navajo", "rue": "Rusyn",
    ]
    /// The Unciv language currently in use.
    static var language: String {
        if let o = override, o != "auto" { return o }
        for pref in Locale.preferredLanguages {
            if let hit = isoToUnciv[pref] { return hit }
            let base = String(pref.split(separator: "-").first ?? "")
            if pref.hasPrefix("zh") { return pref.contains("Hant") || pref.contains("TW") || pref.contains("HK") ? "Traditional_Chinese" : "Simplified_Chinese" }
            if pref.hasPrefix("pt-BR") { return "Brazilian_Portuguese" }
            if let hit = isoToUnciv[base] { return hit }
        }
        return "English"
    }
    /// Unciv LocaleCode.getSystemLanguage: the device's default locale (the first preferred language) as an Unciv
    /// language name, or nil when it has no supported translation (Unciv's empty string).
    static var systemLanguage: String? {
        guard let pref = Locale.preferredLanguages.first else { return nil }
        if let hit = isoToUnciv[pref] { return hit }
        if pref.hasPrefix("zh") { return pref.contains("Hant") || pref.contains("TW") || pref.contains("HK") ? "Traditional_Chinese" : "Simplified_Chinese" }
        if pref.hasPrefix("pt-BR") { return "Brazilian_Portuguese" }
        return isoToUnciv[String(pref.split(separator: "-").first ?? "")]
    }
    /// Unciv LanguageTable.addLanguageTables: one row per percentCompleteOfLanguages entry, English counted as 100,
    /// stable-sorted English first, then the system language, then by completion descending. Shared by the
    /// first-launch LanguagePickerScreen and the options' language tab.
    static func languageTables() -> [(language: String, percent: Int)] {
        let system = systemLanguage
        return Translations.shared.percentageLanguages.enumerated()
            .map { (i, lang) in (i, lang, Translations.shared.percentComplete(lang)) }
            .sorted { a, b in
                let ka = (a.1 == Translations.englishName ? 0 : 1, a.1 == system ? 0 : 1, -a.2)
                let kb = (b.1 == Translations.englishName ? 0 : 1, b.1 == system ? 0 : 1, -b.2)
                return ka != kb ? ka < kb : a.0 < b.0
            }
            .map { (language: $0.1, percent: $0.2) }
    }
    /// Legacy two-letter view of the language ("tr"/"en"), used by a few callers.
    static var current: String { language == "Turkish" ? "tr" : "en" }
    static func reload() {
        let lang = language
        Translations.shared.load(language: lang)
        Translations.shared.setFallback(fallback(lang))
    }
    /// The strings for a language used where Unciv's file has no (or an empty) entry: GameData/UncivFillIns.json (the Unciv
    /// keys a language's file leaves empty that the screens show) and the app's own strings (GameData/EpochsOwnStrings.json,
    /// the strings Unciv has no key for, in every game language), with L10n.turkish over them for Turkish
    static func fallback(_ language: String) -> [String: String] {
        var out = ownTranslations[language] ?? [:]
        if language == "Turkish" { out.merge(turkish) { _, t in t } }
        return out
    }
    /// The stems the Unciv translation files spell "Civilopedia" with, and what the screens show instead (see L())
    static let civilopediaStems: [(String, String)] = [
        ("Civilop", "Uncivlop"), ("civilop", "uncivlop"), ("Zivilop", "Uncivlop"), ("zivilop", "uncivlop"),
        ("Ċivilop", "Uncivlop"), ("ċivilop", "uncivlop"), ("Sibilop", "Uncivlop"), ("sibilop", "uncivlop"),
        ("Sivilop", "Uncivlop"), ("sivilop", "uncivlop"), ("Cywilop", "Uncivlop"), ("cywilop", "uncivlop"), ("Civpedi", "Uncivpedi"),
        ("Цивилопед", "Анцивлопед"), ("цивилопед", "анцивлопед"), ("Цивілопед", "Анцивлопед"), ("цивілопед", "анцивлопед"),
        ("Цівілопед", "Анцівлопед"), ("цівілопед", "анцівлопед"),
        ("シヴィロペディア", "アンシヴロペディア"), ("সিভিলোপিডিয়া", "আনসিভলোপিডিয়া"), ("सिविलोपीडिया", "अनसिवलोपीडिया"),
    ]
    static let ownTranslations: [String: [String: String]] = {
        var out: [String: [String: String]] = [:]
        for name in ["UncivFillIns", "EpochsOwnStrings"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "GameData"),
                  let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for (lang, strings) in obj.compactMapValues({ $0 as? [String: String] }) { out[lang, default: [:]].merge(strings) { a, _ in a } }
        }
        return out
    }()
    nonisolated(unsafe) private static var loaded = false
    static func ensureLoaded() { if !loaded { loaded = true; reload() } }
}

/// Translate with Unciv's engine (bundled Unciv translation files first, then Epochs' own strings).
func L(_ key: String) -> String {
    L10n.ensureLoaded()
    var text = Translations.mapFontIcons(Translations.shared.tr(key))
    // The screens call Unciv's Civilopedia the Uncivlopedia; the keys, key bindings and unique patterns keep "Civilopedia"
    // The app is called Unciv 4X on screen; "Epochs" stays the project's internal name (the tutorial texts, our own strings)
    if text.contains("Epochs") { text = text.replacingOccurrences(of: "Epochs", with: "Unciv 4X") }
    // Many languages translate the word (Zivilopädie, Civilopédia, Цивилопедия, シヴィロペディア …): the stem is swapped so
    // the language's own ending stays (Uncivlopédia, Анцивлопедия)
    for (stem, ours) in L10n.civilopediaStems where text.contains(stem) { text = text.replacingOccurrences(of: stem, with: ours) }
    // a translation that names the original game in its own words (Lithuanian's embarking tutorial: "Civ 5, tam nereikia …")
    if text.contains("Civ 5, tam") { text = text.replacingOccurrences(of: "Civ 5, tam", with: "Tam") }
    return key.hasPrefix("Civ V - ") && Ruleset.baseRulesets.contains(key) ? Ruleset.displayName(translated: text) : text
}

extension Translations {
    /// Unciv Fonts: translations embed single characters that Unciv's font atlas renders as stat/unit icons (¤ gold, ⁂ food, ⍾ science …); Epochs shows the matching emoji.
    static let fontIcons: [(String, String)] = [("¤", "💰"), ("⁂", "🍎"), ("⍾", "🔬"), ("♪", "🎵"), ("⌣", "😊"), ("☮", "🕊"), ("†", "⚔️"), ("‡", "🏹"), ("♡", "❤️"), ("⚒", "🔨"), ("⛤", "⭐"), ("⚖", "⚖️"), ("⚛", "⚛️"), ("☠", "💀")]
    static func mapFontIcons(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { fontIconScalars.contains($0) }) else { return s }
        var out = s
        for (from, to) in fontIcons { out = out.replacingOccurrences(of: from, with: to) }
        return out
    }
    private static let fontIconScalars: Set<Unicode.Scalar> = Set(fontIcons.compactMap { $0.0.unicodeScalars.first })
}
