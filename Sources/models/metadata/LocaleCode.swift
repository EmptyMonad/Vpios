// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv models/metadata/LocaleCode.kt: every language Unciv knows, with the BCP 47 tag its java.util.Locale is made
/// from (`Locale.forLanguageTag`), whether it has a translation in use (`unused`), and the name the settings and the
/// translation files use (`languageName`, the enum name unless given). The tag decides how numbers are written
/// (Number.tr → NumberFormat.getInstance(locale)) and how lists are sorted (getCollatorFromLocale).
enum LocaleCode: String, CaseIterable {
    case Afrikaans, Arabic, Bangla, Belarusian, Bosnian, BrazilianPortuguese, Bulgarian, Catalan, Croatian, Czech, Danish, Dutch,
         English, Esperanto, Estonian, Filipino, Finnish, French, Galician, German, Greek, Hindi, Hungarian, Indonesian, Italian,
         Japanese, Korean, Latin, Latvian, Lithuanian, Malay, Maltese, Navajo, Norwegian, NorwegianNynorsk, PersianPinglishDIN,
         PersianPinglishUN, Polish, Portuguese, Romanian, Russian, Rusyn, Serbian, SimplifiedChinese, Slovak, Spanish, Swedish,
         Thai, TokiPona, TraditionalChinese, Turkish, Ukrainian, Vietnamese, Zulu

    var languageTag: String {
        switch self {
        case .Afrikaans: return "af-ZA"
        case .Arabic: return "ar-IQ"
        case .Bangla: return "bn-BD"
        case .Belarusian: return "be-BY"
        case .Bosnian: return "bs-BA"
        case .BrazilianPortuguese: return "pt-BR"
        case .Bulgarian: return "bg-BG"
        case .Catalan: return "ca-ES"
        case .Croatian: return "hr-HR"
        case .Czech: return "cs-CZ"
        case .Danish: return "da-DK"
        case .Dutch: return "nl-NL"
        case .English: return "en-US"
        case .Esperanto: return "eo"
        case .Estonian: return "et-EE"
        case .Filipino: return "fil-PH-u-co-search"
        case .Finnish: return "fi-FI"
        case .French: return "fr-FR"
        case .Galician: return "gl-ES"
        case .German: return "de-DE"
        case .Greek: return "el-GR"
        case .Hindi: return "hi-IN"
        case .Hungarian: return "hu-HU"
        case .Indonesian: return "in-ID"
        case .Italian: return "it-IT"
        case .Japanese: return "ja-JP"
        case .Korean: return "ko-KR"
        case .Latin: return "la-IT"
        case .Latvian: return "lv-LV"
        case .Lithuanian: return "lt-LT"
        case .Malay: return "ms-MY"
        case .Maltese: return "mt-MT"
        case .Navajo: return "nv-US"
        case .Norwegian: return "no-NO"
        case .NorwegianNynorsk: return "nn-NO"
        case .PersianPinglishDIN, .PersianPinglishUN: return "fa-IR"
        case .Polish: return "pl-PL"
        case .Portuguese: return "pt-PT"
        case .Romanian: return "ro-RO"
        case .Russian: return "ru-RU"
        case .Rusyn: return "rue-SK-u-kr-cyrl-latn-digit"
        case .Serbian: return "sr-RS"
        case .SimplifiedChinese: return "zh-CN"
        case .Slovak: return "sk-SK"
        case .Spanish: return "es-ES"
        case .Swedish: return "sv-SE"
        case .Thai: return "th-TH"
        case .TokiPona: return "tok"
        case .TraditionalChinese: return "zh-TW"
        case .Turkish: return "tr-TR"
        case .Ukrainian: return "uk-UA"
        case .Vietnamese: return "vi-VN"
        case .Zulu: return "zu-ZA"
        }
    }
    /// Languages without a translation in use (`unused = true`).
    var unused: Bool { [.Arabic, .Danish, .Estonian, .Latvian, .NorwegianNynorsk, .Serbian, .Slovak].contains(self) }
    /// LocaleCode.languageName(): the settings' and the translation file's name.
    var languageName: String {
        switch self {
        case .BrazilianPortuguese: return "Brazilian_Portuguese"
        case .PersianPinglishDIN: return "Persian_(Pinglish-DIN)"
        case .PersianPinglishUN: return "Persian_(Pinglish-UN)"
        case .SimplifiedChinese: return "Simplified_Chinese"
        case .TokiPona: return "Toki_Pona"
        case .TraditionalChinese: return "Traditional_Chinese"
        default: return rawValue
        }
    }
    /// LocaleCode.locale(): `Locale.forLanguageTag(languageTag)`.
    var locale: Locale { Locale(identifier: languageTag) }
    /// Java's Locale.getLanguage()/getCountry() of forLanguageTag - "in" stays Java's legacy code for Indonesian.
    private var languageAndCountry: (String, String) {
        let parts = languageTag.split(separator: "-").map(String.init)
        let country = parts.count > 1 && parts[1].count == 2 ? parts[1] : ""
        return (parts[0], country)
    }

    /// LocaleCode.find(language): the entry whose languageName is the settings' language.
    static func find(_ language: String) -> LocaleCode? { allCases.first { $0.languageName == language } }
    /// LocaleCode.find(locale): the first used entry with the same language and country (softEquals - script, variant and
    /// extensions ignored). `language`/`country` are Java's: Java writes Indonesian "in", Hebrew "iw", Yiddish "ji".
    static func find(language: String, country: String) -> LocaleCode? {
        let javaLanguage = ["id": "in", "he": "iw", "yi": "ji"][language] ?? language
        return allCases.first { !$0.unused && $0.languageAndCountry == (javaLanguage, country) }
    }
    /// LocaleCode.getLocale(language): the language's locale, or the device's default for a language Unciv does not know.
    static func getLocale(_ language: String) -> Locale { find(language)?.locale ?? Locale.current }
    /// LocaleCode.getSupportedLanguages().
    static var supportedLanguages: [String] { allCases.filter { !$0.unused }.map(\.languageName) }
    /// LocaleCode.getSystemLanguage(): `find(UncivGame.Current.getDefaultLocale())` - the device's default locale (on
    /// iOS the first preferred language, as Android's LocaleList.getDefault()[0]) - as a settings language name, or nil
    /// (Unciv's empty string) when no used entry has its language and country.
    static var systemLanguage: String? {
        guard let pref = Locale.preferredLanguages.first else { return nil }
        let l = Locale(identifier: pref)
        let language = l.language.languageCode?.identifier ?? ""
        let country = l.region?.identifier ?? Locale.current.region?.identifier ?? ""
        return find(language: language, country: country)?.languageName
    }

    /// The symbols java.text.DecimalFormatSymbols gives this locale on the reference JDK (OpenJDK 19, its CLDR data),
    /// measured against the reference JDK (NFMT lines): zero digit, grouping separator, decimal
    /// separator and the negative prefix. NumberFormat.getInstance is "#,##0.###" in every one of them.
    var javaNumberSymbols: (zero: UInt32, group: Character, decimal: Character, negativePrefix: String) {
        switch self {
        case .English, .Filipino, .Hindi, .Japanese, .Korean, .Latin, .Malay, .Maltese, .Navajo, .NorwegianNynorsk, .Rusyn,
             .SimplifiedChinese, .Thai, .TokiPona, .TraditionalChinese, .Zulu:
            return (0x30, ",", ".", "-")
        case .Bosnian, .BrazilianPortuguese, .Catalan, .Danish, .Dutch, .Galician, .German, .Greek, .Indonesian, .Italian,
             .Romanian, .Serbian, .Spanish, .Turkish, .Vietnamese:
            return (0x30, ".", ",", "-")
        case .Croatian: return (0x30, ".", ",", "\u{2212}")
        case .Afrikaans, .Belarusian, .Bulgarian, .Czech, .Esperanto, .Hungarian, .Latvian, .Polish, .Portuguese, .Russian,
             .Slovak, .Ukrainian:
            return (0x30, "\u{A0}", ",", "-")
        case .Estonian, .Finnish, .Lithuanian, .Norwegian, .Swedish: return (0x30, "\u{A0}", ",", "\u{2212}")
        case .French: return (0x30, "\u{202F}", ",", "-")
        case .Bangla: return (0x9E6, ",", ".", "-")
        case .Arabic: return (0x660, "\u{66C}", "\u{66B}", "\u{61C}-")
        case .PersianPinglishDIN, .PersianPinglishUN: return (0x6F0, "\u{66C}", "\u{66B}", "\u{200E}\u{2212}")
        }
    }

    /// LocaleCode.getNumberFormatFromLanguage(language).format(v) - Unciv's Number.tr(language): java.text.DecimalFormat
    /// "#,##0.###" with the language's symbols: every three integer digits grouped (no minimum grouping digits, no Indian
    /// grouping - ICU's own formats differ there: Spanish 1500, Hindi 12,34,567), at most three fraction digits rounded
    /// HALF_EVEN from the shortest decimal form, no trailing zeros. A language Unciv does not know is formatted as the
    /// device's language (Locale.getDefault()), English when that is not one either.
    static func format(_ v: Double, language: String) -> String {
        if v.isNaN { return "NaN" }
        let sy = (find(language) ?? systemLocaleCode ?? .English).javaNumberSymbols
        if v.isInfinite { return (v < 0 ? sy.negativePrefix : "") + "\u{221E}" }
        let plain = posix.string(from: NSNumber(value: v)) ?? String(v)   // "-1234.568", HALF_EVEN, no grouping
        return javaDigits(plain, sy)
    }
    static func format(_ v: Int64, language: String) -> String {
        javaDigits(String(v), (find(language) ?? systemLocaleCode ?? .English).javaNumberSymbols)
    }
    static func format(_ v: Int, language: String) -> String { format(Int64(v), language: language) }
    private static func javaDigits(_ plain: String, _ sy: (zero: UInt32, group: Character, decimal: Character, negativePrefix: String)) -> String {
        var s = Substring(plain)
        let negative = s.first == "-"
        if negative { s = s.dropFirst() }
        let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        func digits(_ t: Substring) -> String {
            String(String.UnicodeScalarView(t.unicodeScalars.map { c in
                (0x30...0x39).contains(c.value) ? Unicode.Scalar(sy.zero + c.value - 0x30)! : c
            }))
        }
        let int = Array(parts[0])
        var grouped = ""
        for (i, ch) in int.enumerated() {
            if i > 0 && (int.count - i) % 3 == 0 { grouped.append(sy.group) }
            grouped.append(ch)
        }
        var out = (negative ? sy.negativePrefix : "") + digits(Substring(grouped))
        if parts.count > 1, !parts[1].isEmpty { out.append(sy.decimal); out += digits(parts[1]) }
        return out
    }
    /// The rounding half of the format: plain ASCII digits, HALF_EVEN to three decimals, no grouping.
    private static let posix: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 3
        f.minimumIntegerDigits = 1
        f.roundingMode = .halfEven
        return f
    }()
    /// LocaleCode.find(Locale.getDefault()) without the `unused` filter (getLocale's fallback is the default locale itself).
    private static var systemLocaleCode: LocaleCode? {
        guard let pref = Locale.preferredLanguages.first else { return nil }
        let l = Locale(identifier: pref)
        let language = l.language.languageCode?.identifier ?? ""
        let country = l.region?.identifier ?? Locale.current.region?.identifier ?? ""
        let javaLanguage = ["id": "in", "he": "iw", "yi": "ji"][language] ?? language
        return allCases.first { $0.languageAndCountry == (javaLanguage, country) }
    }
}

extension LocaleCode {
    /// Unciv GameSettings.getCollatorFromLocale: `Collator.getInstance(getCurrentLocale())` - the game language's
    /// locale, not the device's, and a plain comparison (no numeric ordering, case and accents both counted).
    ///
    /// java.text.Collator (the JDK's RuleBasedCollator, not ICU) makes whitespace and the hyphen-minus secondary
    /// differences - ignored unless the strings are otherwise equal - where ICU orders them before every letter: measured
    /// by PediaProbe `locale` (COLL2), "Goddess of Love" < "God of Craftsman" < "Godofwar" and "ab" < "a b" < "a-b" in
    /// every language. So the strings are compared without them first, then with fewer of them first, space before
    /// hyphen. (What else the legacy JDK rules order differently from ICU - letters they do not list, such as ı, Ł, ø
    /// or Cyrillic in a Latin locale, sorted after every listed one - is not followed; MIRROR.md.)
    static func compare(_ a: String, _ b: String, language: String = Translations.shared.language) -> ComparisonResult {
        let locale = getLocale(language)
        let pa = javaPrimary(a), pb = javaPrimary(b)
        let r = pa.compare(pb, options: [], range: nil, locale: locale)
        if r != .orderedSame { return r }
        let ia = a.unicodeScalars.count - pa.unicodeScalars.count, ib = b.unicodeScalars.count - pb.unicodeScalars.count
        if ia != ib { return ia < ib ? .orderedAscending : .orderedDescending }
        if ia == 0 { return a.compare(b, options: [], range: nil, locale: locale) }
        let ka = String(a.map { $0 == "-" ? "\u{2}" : $0.isWhitespace ? "\u{1}" : $0 }), kb = String(b.map { $0 == "-" ? "\u{2}" : $0.isWhitespace ? "\u{1}" : $0 })
        return ka == kb ? .orderedSame : (ka.unicodeScalars.lexicographicallyPrecedes(kb.unicodeScalars) ? .orderedAscending : .orderedDescending)
    }
    /// The string as the JDK collator's primary level sees it: whitespace and "-" dropped.
    private static func javaPrimary(_ s: String) -> String {
        guard s.contains(where: { $0 == "-" || $0.isWhitespace }) else { return s }
        return String(s.filter { $0 != "-" && !$0.isWhitespace })
    }
}
