// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Yield stats shared by terrains, buildings, improvements, resources.
struct Stats: Codable, Equatable {
    /// Unciv Stats.toString: "+3 Culture, +2 Faith", the form its notifications are written in.
    var uncivText: String {
        var parts: [String] = []
        // Unciv stringify(): the iterator order is Production, Food, Gold, Science, Culture,
        // Happiness, Faith, and the amount is `it.value.toInt()` - truncated, never fractional.
        func add(_ v: Double, _ n: String) { if v != 0 { parts.append("\(v > 0 ? "+" : "")\(Int(v)) \(n)") } }
        add(production, "Production"); add(food, "Food"); add(gold, "Gold"); add(science, "Science"); add(culture, "Culture"); add(happiness, "Happiness"); add(faith, "Faith")
        return parts.joined(separator: ", ")
    }
    /// Unciv Stats.toString() itself - stringify() with every default, built in the game's language as Unciv builds it:
    /// the amount through Number.tr() (that language's NumberFormat, "1,000" / "1.000") and each stat's name through
    /// `name.tr(hideStats = false)` behind its font character - "+100 ¤Gold" in English, "+100 ¤Altın" in Turkish, which
    /// the notification keeps as it is (no stats string for translateIndividualWord to re-translate).
    /// Only the natural wonder's discovery notification is written with it.
    var uncivTextWithIcons: String {
        L10n.ensureLoaded()   // the settings' language, as UncivGame.Current.settings.language always is
        var parts: [String] = []
        func add(_ v: Double, _ n: String, _ icon: String) {
            if v != 0 { parts.append("\(v > 0 ? "+" : "")\(Translations.shared.numberTr(Int(v))) \(icon)\(Translations.shared.tr(n))") }
        }
        add(production, "Production", "\u{2699}"); add(food, "Food", "\u{2042}"); add(gold, "Gold", "\u{00A4}"); add(science, "Science", "\u{237E}")
        add(culture, "Culture", "\u{266A}"); add(happiness, "Happiness", "\u{2323}"); add(faith, "Faith", "\u{262E}")
        return parts.joined(separator: ", ")
    }

    var food: Double = 0
    var production: Double = 0
    var gold: Double = 0
    var science: Double = 0
    var culture: Double = 0
    var happiness: Double = 0
    var faith: Double = 0

    static let zero = Stats()

    /// Unciv's `Stats` are Float, and its city stats multiply each SOURCE by the percentage before summing.
    /// Rounding a Double result through Float reproduces Float arithmetic exactly - a single operation
    /// computed wide and then rounded once is the correctly-rounded narrow result - so this is how the
    /// mirrored CityStats gets Unciv's answer without turning every yield in the engine into a Float.
    /// Measured on `settled` turn 65: Unciv's Carthage sums 2.6999998 + 9.9 + 0.9 = 13.499999046 and banks
    /// 13 hammers, where our one Double multiply, 15 x 0.9, is exactly 13.5 and banks 14.
    @inline(__always) static func f32(_ x: Double) -> Double { Double(Float(x)) }
    /// Kotlin `roundToInt()` is Java `Math.round`: floor(x + 0.5), so -0.5 goes to 0 where Swift's `.rounded()`
    /// goes to -1 (half away from zero). They differ only on negative halves.
    @inline(__always) static func roundToInt(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }
    /// Kotlin `Double.roundToInt()` whole: IllegalArgumentException("Cannot round NaN value.") on NaN, Int.MAX_VALUE /
    /// Int.MIN_VALUE beyond them (the infinities too), Math.round in between - where `roundToInt` above stops the app on
    /// all three.
    static func kotlinRoundToInt(_ x: Double) throws -> Int {
        if x.isNaN { throw RoundNaNError() }
        if x > Double(Int32.max) { return Int(Int32.max) }
        if x < Double(Int32.min) { return Int(Int32.min) }
        return roundToInt(x)
    }
    /// Kotlin's `IllegalArgumentException("Cannot round NaN value.")` from Double.roundToInt
    struct RoundNaNError: Error, CustomStringConvertible { var description: String { "Cannot round NaN value." } }

    /// Every field rounded to Float, as Unciv holds them.
    var f32: Stats {
        Stats(food: Stats.f32(food), production: Stats.f32(production), gold: Stats.f32(gold),
              science: Stats.f32(science), culture: Stats.f32(culture),
              happiness: Stats.f32(happiness), faith: Stats.f32(faith))
    }

    /// Unciv `Float.toPercent()`: `1f + this / 100f`, in Float.
    static func toPercent(_ v: Double) -> Double { Stats.f32(1 + Stats.f32(Stats.f32(v) / 100)) }   // `this/100` is a Float division, rounded before the add

    /// Unciv Stats.plus / add: every field is a Float, so each sum is rounded to Float - which is exactly a
    /// Double sum of two Float values rounded once.
    static func + (a: Stats, b: Stats) -> Stats {
        Stats(food: f32(a.food + b.food), production: f32(a.production + b.production), gold: f32(a.gold + b.gold),
              science: f32(a.science + b.science), culture: f32(a.culture + b.culture),
              happiness: f32(a.happiness + b.happiness), faith: f32(a.faith + b.faith))
    }
    static func += (a: inout Stats, b: Stats) { a = a + b }

    var isEmpty: Bool { self == .zero }

    /// Compact "2F 1P 1G" style description used in the UI.
    /// Unciv ImprovementPickerScreen: a yield change, kept to one decimal, zeros left out, and a sign so a
    /// loss reads as a loss.
    var delta: String {
        var parts: [String] = []
        func add(_ v: Double, _ icon: String) {
            let rounded = (v * 10).rounded() / 10
            guard rounded != 0 else { return }
            let text = rounded.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(rounded)) : String(format: "%.1f", rounded)
            parts.append("\(rounded > 0 ? "+" : "")\(text)\(icon)")
        }
        add(food, "🍎"); add(production, "⚙️"); add(gold, "💰"); add(science, "🔬"); add(culture, "🎵"); add(happiness, "😊"); add(faith, "🕊")
        return parts.joined(separator: " ")
    }

    var short: String {
        var parts: [String] = []
        if food != 0 { parts.append("\(Int(food))🍎") }
        if production != 0 { parts.append("\(Int(production))⚙️") }
        if gold != 0 { parts.append("\(Int(gold))💰") }
        if science != 0 { parts.append("\(Int(science))🔬") }
        if culture != 0 { parts.append("\(Int(culture))🎵") }
        if happiness != 0 { parts.append("\(Int(happiness))😊") }
        if faith != 0 { parts.append("\(Int(faith))🕊") }
        return parts.joined(separator: " ")
    }

    private enum CodingKeys: String, CodingKey { case food, production, gold, science, culture, happiness, faith }
    init() {}
    init(food: Double = 0, production: Double = 0, gold: Double = 0, science: Double = 0, culture: Double = 0, happiness: Double = 0, faith: Double = 0) {
        self.food = food; self.production = production; self.gold = gold; self.science = science
        self.culture = culture; self.happiness = happiness; self.faith = faith
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        food = try c.decodeIfPresent(Double.self, forKey: .food) ?? 0
        production = try c.decodeIfPresent(Double.self, forKey: .production) ?? 0
        gold = try c.decodeIfPresent(Double.self, forKey: .gold) ?? 0
        science = try c.decodeIfPresent(Double.self, forKey: .science) ?? 0
        culture = try c.decodeIfPresent(Double.self, forKey: .culture) ?? 0
        happiness = try c.decodeIfPresent(Double.self, forKey: .happiness) ?? 0
        faith = try c.decodeIfPresent(Double.self, forKey: .faith) ?? 0
    }
}
