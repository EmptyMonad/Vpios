// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv's translation engine (core/models/translations/Translations.kt) reading the bundled Unciv `.properties` files:
/// `[placeholder]` keys, `{sub-sentence}` parts, `<conditional>` ordering and the per-language rules (space equivalent,
/// StartWithCapitalLetter, ConditionalsOrder / ConditionalsPlacement, EffectBeforeCause).
final class Translations {
    nonisolated(unsafe) static let shared = Translations()

    static let directory = "GameData/Translations"
    static let englishName = "English"
    private(set) var language: String = Translations.englishName
    /// The language's locale (Unciv LocaleCode.getLocale), whose number format the translated text uses.
    var numberLocale: Locale { LocaleCode.getLocale(language) }
    /// Unciv `Number.tr()`: `settings.getCurrentNumberFormat().format(this)`, java.text.NumberFormat.getInstance for the
    /// language's locale (LocaleCode.getNumberFormatFromLanguage) - grouped digits ("1,005", "1.005", "1 005"), at most
    /// three decimals rounded half-even, no trailing zeros.
    func numberTr(_ v: Double) -> String { LocaleCode.format(v, language: language) }
    /// Unciv `Number.tr()` of a Long/Int.
    func numberTr(_ v: Int) -> String { LocaleCode.format(v, language: language) }
    private var entries: [String: Entry] = [:]
    private var fallback: [String: Entry] = [:]     // Epochs' own strings (see L10n.turkish)
    /// Unciv Translations.modsWithTranslations: every installed mod's `jsons/translations/<language>.properties`, by mod name.
    private var modEntries: [String: [String: Entry]] = [:]
    private var loadedLanguage: String? = nil

    /// All languages that have a bundled translation file, plus their completion percentage (completionPercentages.properties).
    private(set) lazy var percentages: [String: Int] = {
        var out: [String: Int] = [:]
        if let url = Bundle.main.url(forResource: "completionPercentages", withExtension: "properties", subdirectory: Translations.directory),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            for (k, v) in Translations.parseProperties(text) { out[k] = Int(v.trimmingCharacters(in: .whitespaces)) ?? 0 }
        }
        return out
    }()
    /// Unciv Translations.percentCompleteOfLanguages: readLanguagePercentages fills a java.util.HashMap from
    /// completionPercentages.properties, so its keys iterate in Java bucket order - the order LanguageTable's
    /// stable sort starts from.
    private(set) lazy var percentageLanguages: [String] = {
        guard let url = Bundle.main.url(forResource: "completionPercentages", withExtension: "properties", subdirectory: Translations.directory),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var keys: [String] = []
        for (k, _) in Translations.parseProperties(text) where !keys.contains(k) { keys.append(k) }
        return javaHashMapOrder(keys)
    }()
    /// Unciv LanguageTable.addLanguageTables: the rows come only from percentCompleteOfLanguages
    /// (TranslationFileReader.readLanguagePercentages), never from the bundled files, so template.properties is no language.
    private(set) lazy var languages: [String] = {
        var names = Array(percentages.keys)
        if !names.contains(Translations.englishName) { names.append(Translations.englishName) }
        return names.sorted { (percentages[$0] ?? 0, $1) > (percentages[$1] ?? 0, $0) }
    }()
    /// Unciv LanguageTable.addLanguageTables: `LanguageTable(it.key, if (it.key == Constants.english) 100 else it.value)` -
    /// English always reads 100%.
    func percentComplete(_ language: String) -> Int { language == Translations.englishName ? 100 : (percentages[language] ?? 0) }

    // MARK: loading

    /// Unciv Translations.createTranslations: keys with square brackets (and no conditionals) are hashed by their placeholder text.
    static func hashKey(_ key: String) -> String {
        key.contains("[") && !key.contains("<") ? placeholderText(key) : key
    }

    func load(language: String) {
        self.language = language
        guard loadedLanguage != language else { return }
        loadedLanguage = language
        entries = [:]
        modEntries = Translations.readModTranslations(language: language)
        // Unciv tryReadTranslationForLanguage reads English.properties too: its few non-empty entries
        // ("Comment [comment] = [comment]", the Water* unit types …) apply in English as well.
        guard let url = Bundle.main.url(forResource: language, withExtension: "properties", subdirectory: Translations.directory),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for (k, v) in Translations.parseProperties(text) where !v.trimmingCharacters(in: .whitespaces).isEmpty {
            // Unciv's generated files keep untranslated keys with an empty value; those fall back to English.
            entries[Translations.hashKey(k)] = Entry(original: k, value: v)
        }
    }

    /// Epochs' own (non-Unciv) strings for the current language, used when the Unciv file has no entry.
    func setFallback(_ dict: [String: String]) {
        fallback = [:]
        for (k, v) in dict { fallback[Translations.hashKey(k)] = Entry(original: k, value: v) }
    }

    /// Unciv tryReadTranslationForLanguage: the mods' files are read with the base one - each mod's entries kept apart
    /// (createTranslations on its own Translations), keys hashed the same way, empty values left out by the reader
    /// (TranslationFileReader.read: `if (splitLine[1].isNotEmpty())`). Unciv's reader decodes UTF-8 with the replacement
    /// character for a malformed byte (InputStreamReader); `String(contentsOf:encoding:)` gave nil and the whole file was skipped.
    static func readModTranslations(language: String) -> [String: [String: Entry]] {
        var out: [String: [String: Entry]] = [:]
        for mod in Ruleset.availableMods() {
            let url = Ruleset.modsDirectory.appendingPathComponent(mod).appendingPathComponent("jsons/translations/\(language).properties")
            guard let data = try? Data(contentsOf: url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            var modDict: [String: Entry] = [:]
            for (k, v) in Translations.parseProperties(text) where !v.isEmpty {
                modDict[Translations.hashKey(k)] = Entry(original: k, value: v)
            }
            if !modDict.isEmpty { out[mod] = modDict }
        }
        return out
    }
    /// Unciv ModManagementScreen.reloadCachesAfterModChange: `translations.tryReadTranslationForCurrentLanguage()` once a
    /// mod is downloaded or deleted, so its translations come and go with it.
    func reloadModTranslations() { modEntries = Translations.readModTranslations(language: language) }

    /// Unciv Translations.get(text, language, activeMods): the active mods' translations first - the game's mods, then its
    /// base ruleset (TranslationActiveModsCache) - and the base file after them.
    func entry(_ key: String) -> Entry? {
        entry(key, activeMods: modEntries.isEmpty ? [] : Ruleset.shared.mods + [Ruleset.currentBaseRuleset])
    }
    func entry(_ key: String, activeMods: [String]) -> Entry? {
        for mod in activeMods { if let e = modEntries[mod]?[key] { return e } }
        return entries[key] ?? fallback[key]
    }
    /// Whether the language's Unciv file itself has the (hashed) key - Epochs' own strings (L10n) not asked.
    func inUncivFile(_ key: String) -> Bool { entries[key] != nil }

    // MARK: missing-key log (debugging aid, off unless EPOCHS_LOG_MISSING_TR=1)

    /// `EPOCHS_LOG_MISSING_TR=1` in the app's environment (`SIMCTL_CHILD_EPOCHS_LOG_MISSING_TR=1 xcrun simctl launch …`):
    /// every key tr() looks up and finds neither in an active mod's file, nor in the language's Unciv file, nor among
    /// Epochs' own strings is printed once, as `MISSINGTR <kind>\t<key>\t<text>` - `ph` a placeholder key (`[]` for each parameter), `word` a plain one,
    /// the text the one tr() was asked to translate. Keys with no letter (numbers, icons) are left out. Without the
    /// variable nothing is looked up twice and nothing is printed.
    static let logMissing = ProcessInfo.processInfo.environment["EPOCHS_LOG_MISSING_TR"] == "1"
    private static let missingLock = NSLock()
    nonisolated(unsafe) private static var missingSeen = Set<String>()
    private func noteMissing(_ kind: String, _ key: String, _ text: String) {
        guard !isEnglish, key.contains(where: { $0.isLetter }) else { return }
        Translations.missingLock.lock()
        let isNew = Translations.missingSeen.insert(key).inserted
        Translations.missingLock.unlock()
        guard isNew else { return }
        let esc = { (s: String) in s.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: " ") }
        print("MISSINGTR \(kind)\t\(esc(key))\t\(esc(text))")
        fflush(stdout)
    }
    /// Unciv getText(key, language, null, default): the language rules are read without the mods' translations.
    func text(_ key: String, default def: String? = nil) -> String { (entries[key] ?? fallback[key])?.value ?? def ?? key }
    var isEnglish: Bool { language == Translations.englishName }

    // MARK: language rules

    var spaceEquivalent: String { let s = text("\" \"", default: "\" \""); return s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 ? String(s.dropFirst().dropLast()) : s }
    // Kotlin String.toBoolean(): "true" ignoring case
    var shouldCapitalize: Bool { text("StartWithCapitalLetter", default: "true").lowercased() == "true" }
    var conditionalsAfterUnique: Bool { text("ConditionalsPlacement", default: "") != "before" }
    var effectBeforeCause: Bool { text("EffectBeforeCause", default: "true").lowercased() == "true" }
    static let defaultConditionalOrder = "<with a garrison> <for [mapUnitFilter] units> <when above [amount] HP> <when below [amount] HP> <vs cities> <vs [mapUnitFilter] units> <when fighting in [tileFilter] tiles> <when attacking> <when defending> <when at war> <when not at war> <while the empire is happy> <during a Golden Age> <during the [era]> <starting from the [era]> <before the [era]> <with [techOrPolicy]> <without [techOrPolicy]>"
    var conditionalOrder: String { text("ConditionalsOrder", default: Translations.defaultConditionalOrder) }

    // MARK: placeholder helpers (Unciv TranslationExtensions)

    /// `[anything]` → `[]`, only the outermost bracket level.
    static func placeholderText(_ s: String) -> String {
        var out = ""; var depth = 0
        for ch in s {
            if ch == "[" { if depth == 0 { out.append("[") }; depth += 1 }
            else if ch == "]" { depth = max(0, depth - 1); if depth == 0 { out.append("]") } }
            else if depth == 0 { out.append(ch) }
        }
        return out
    }
    /// Contents of the outermost `[…]` groups, in order.
    static func placeholderParameters(_ s: String) -> [String] {
        var out: [String] = []; var depth = 0; var cur = ""
        for ch in s {
            if ch == "[" { if depth > 0 { cur.append(ch) }; depth += 1 }
            else if ch == "]" { depth -= 1; if depth == 0 { out.append(cur); cur = "" } else if depth > 0 { cur.append(ch) } else { depth = 0 } }
            else if depth > 0 { cur.append(ch) }
        }
        return out
    }
    static func conditionals(_ s: String) -> [String] {
        var out: [String] = []; var cur = ""; var inside = false
        for ch in s {
            if ch == "<" { inside = true; cur = "" }
            else if ch == ">" && inside { out.append(cur); inside = false }
            else if inside { cur.append(ch) }
        }
        return out
    }
    static func removeConditionals(_ s: String) -> String {
        var out = ""; var inside = false
        for ch in s { if ch == "<" { inside = true } else if ch == ">" && inside { inside = false } else if !inside { out.append(ch) } }
        return out.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }
    private static func hasPointy(_ s: String) -> Bool {
        guard let a = s.firstIndex(of: "<"), let b = s.lastIndex(of: ">") else { return false }
        return a < b
    }

    // MARK: String.tr()

    func tr(_ text: String) -> String {
        // Unciv's tr() never short-circuits: even with no translation entry it still strips the square and
        // curly brackets, which is what makes "Buy for [1500] gold" read as "Buy for 1500 gold" in English.
        if Translations.hasPointy(text) { return translateConditionals(text) }
        let sq = text.firstIndex(of: "["), cu = text.firstIndex(of: "{")
        if let s = sq, cu == nil || cu! > s { return translatePlaceholders(text) }
        if let c = cu, sq == nil || sq! > c { return translateCurly(text) }
        return translateIndividualWord(text)
    }

    private func translateCurly(_ text: String) -> String {
        var out = ""; var cur = ""; var inside = false
        for ch in text {
            if ch == "{" && !inside { inside = true; cur = "" }
            else if ch == "}" && inside { inside = false; out += tr(cur) }
            else if inside { cur.append(ch) } else { out.append(ch) }
        }
        if inside { out += "{" + cur }
        return out
    }

    private func translatePlaceholders(_ text: String) -> String {
        let key = Translations.placeholderText(text)
        let terms = Translations.placeholderParameters(text)
        guard let e = entry(key) else {
            if Translations.logMissing { noteMissing("ph", key, text) }
            // No translation: still translate the parameters (Unciv keeps the English template).
            var out = text
            for t in terms { out = out.replacingOccurrences(of: "[\(t)]", with: tr(t)) }
            return out
        }
        let names = Translations.placeholderParameters(e.original)
        guard names.count == terms.count else { return text }
        var out = e.value
        for i in terms.indices { out = out.replacingOccurrences(of: "[\(names[i])]", with: tr(terms[i])) }
        return out
    }

    private func translateConditionals(_ text: String) -> String {
        let order = Translations.conditionals(conditionalOrder).map { Translations.placeholderText($0) }
        var priority: [String: Int] = [:]
        for (i, k) in order.enumerated() where priority[k] == nil { priority[k] = i }
        // Unciv sortedBy is a *stable* sort: conditionals the ConditionalsOrder does not list all
        // share Int.MAX_VALUE and must keep the order they were written in. Swift's sort is not
        // stable, so the original index is the tie-break.
        let conds = Translations.conditionals(text)
            .enumerated()
            .map { (Translations.placeholderText($0.element), $0.element, $0.offset) }
            .sorted { a, b in
                let pa = priority[a.0] ?? Int.max, pb = priority[b.0] ?? Int.max
                return pa != pb ? pa < pb : a.2 < b.2
            }
            .map { "<" + tr($0.1) + ">" }
            .map { String($0.dropFirst().dropLast()) }
        let base = tr(Translations.removeConditionals(text))
        var parts: [String] = []
        if conditionalsAfterUnique { parts.append(base); parts += conds }
        else { parts += conds; parts.append(shouldCapitalize ? base.prefix(1).lowercased() + base.dropFirst() : base) }
        var full = parts.joined(separator: spaceEquivalent)
        if shouldCapitalize, let f = full.first { full = f.uppercased() + full.dropFirst() }
        return full
    }

    private func translateIndividualWord(_ text: String) -> String {
        if Translations.isStats(text) { return Translations.translateStats(text, tr: { self.translateIndividualWord($0) }) }   // Unciv Stats.isStats → stats.toString()
        // Unciv: getText() returns the text itself when untranslated, and the digit regex still runs on it.
        let found = entry(text)
        if found == nil && Translations.logMissing { noteMissing("word", text, text) }
        return Translations.formatDigitRuns(found?.value ?? text, language: language)
    }
    static let statNames = ["Production", "Food", "Gold", "Science", "Culture", "Happiness", "Faith"]
    /// Unciv Stats.isStats: "+3 Culture" / "+1 Production, -1 Food" (every value signed).
    static func isStats(_ s: String) -> Bool {
        guard let first = s.first, first == "+" || first == "-" else { return false }
        return s.components(separatedBy: ", ").allSatisfy { part in
            let bits = part.split(separator: " ", maxSplits: 1).map(String.init)
            guard bits.count == 2, let f = bits[0].first, f == "+" || f == "-", Int(bits[0].dropFirst()) != nil else { return false }
            return statNames.contains(bits[1])
        }
    }
    /// Unciv's font characters for the stats, which mapFontIcons turns into emoji.
    static let statIcons: [String: String] = ["Production": "⚒", "Food": "⁂", "Gold": "¤", "Science": "⍾", "Culture": "♪", "Happiness": "⌣", "Faith": "☮"]

    /// Unciv translateIndividualWord: a stats string is parsed and re-stringified, so it comes back in the
    /// canonical stat order with duplicates summed, zeroes dropped, and each name carrying its icon.
    static func translateStats(_ s: String, tr: (String) -> String) -> String {
        var amounts: [String: Int] = [:]
        for part in s.components(separatedBy: ", ") {
            let bits = part.split(separator: " ", maxSplits: 1).map(String.init)
            guard bits.count == 2, let v = Int(bits[0]) else { continue }
            amounts[bits[1], default: 0] += v
        }
        return statNames.compactMap { name -> String? in
            guard let v = amounts[name], v != 0 else { return nil }
            return "\(v > 0 ? "+" : "")\(v) \(statIcons[name] ?? "")\(tr(name))"
        }.joined(separator: ", ")
    }

    /// Unciv translateIndividualWord: `.replace(digitsRegex) { it.value.toLong().tr(language) }` - every run of ASCII digits
    /// (`\d+`, Java's default classes) in the translated word is written again by the language's NumberFormat, short runs
    /// and leading zeros included ("007" reads "7", "1500" reads "1,500" / "1.500" / "১,৫০০"). A run too long for a Long,
    /// which stops Unciv (NumberFormatException), is left as it is.
    static func formatDigitRuns(_ s: String, language: String) -> String {
        guard s.utf8.contains(where: { $0 >= 0x30 && $0 <= 0x39 }) else { return s }
        var out = "", run = ""
        func flush() {
            guard !run.isEmpty else { return }
            out += Int64(run).map { LocaleCode.format($0, language: language) } ?? run
            run = ""
        }
        for ch in s { if ch.isASCII, ch.isNumber { run.append(ch) } else { flush(); out.append(ch) } }
        flush()
        return out
    }
}

extension String {
    /// Unciv `String.tr()`.
    var tr: String { Translations.mapFontIcons(Translations.shared.tr(self)) }
    /// Unciv `fillPlaceholders`: replace each `[x]` in order with the given values.
    func fillPlaceholders(_ values: String...) -> String {
        let names = Translations.placeholderParameters(self)
        var out = self
        for (i, v) in values.enumerated() where i < names.count { out = out.replacingOccurrences(of: "[\(names[i])]", with: v) }
        return out
    }
}
