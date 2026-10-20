// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv HolidayDates: which easter-egg holiday (if any) today falls into; `easterEgg` launch argument forces one.
enum HolidayDates {
    enum Holiday: String, CaseIterable {
        case Easter, Samhain, Xmas, DiaDeLosMuertos, YuleGoat, Qingming, Diwali, LunarNewYear, AprilFoolsDay, PrideDay, TowelDay, UncivBirthday, Friday13th, StarWarsDay, Passover

        var chance: Double {
            switch self { case .DiaDeLosMuertos: return 0.5; case .Diwali: return 0.2; case .PrideDay: return 0.333; case .Passover: return 0.2; default: return 1 }
        }

        func range(year: Int) -> ClosedRange<Date>? {
            let cal = HolidayDates.calendar
            func date(_ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: year, month: m, day: d))! }
            func span(_ start: Date, _ days: Int) -> ClosedRange<Date> { start...cal.date(byAdding: .day, value: days - 1, to: start)! }
            switch self {
            case .Easter:
                // Anonymous Gregorian algorithm, as in Unciv.
                let a = year % 19, b = year / 100, c = year % 100, d = b / 4, e = b % 4, g = (8 * b + 13) / 25
                let h = (19 * a + b - d - g + 15) % 30, i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7
                let m = (a + 11 * h + 19 * l) / 433, n = (h + l - 7 * m + 90) / 25, p = (h + l - 7 * m + 33 * n + 19) % 32
                return span(cal.date(byAdding: .day, value: -2, to: date(n, p))!, 4)
            case .Samhain: return span(date(10, 31), 1)
            case .Xmas: return span(date(12, 24), 4)
            case .DiaDeLosMuertos: return span(date(11, 1), 2)
            case .YuleGoat: return span(HolidayDates.closestWeekday(date(11, 30), weekday: 1), 1)
            case .Qingming: return span(cal.date(byAdding: .day, value: 15, to: date(3, 20))!, 1)   // spring equinox + 15 days
            case .Diwali:
                guard let d = HolidayDates.diwali[year] else { return nil }
                return span(cal.date(byAdding: .day, value: -2, to: date(d.0, d.1))!, 5)
            case .LunarNewYear:
                guard let dayOfYear = HolidayDates.lunarNewYear[year] else { return nil }
                return span(cal.date(byAdding: .day, value: dayOfYear - 1, to: date(1, 1))!, 1)
            case .AprilFoolsDay: return span(date(4, 1), 1)
            case .PrideDay: return span(date(6, 28), 3)
            case .TowelDay: return span(date(5, 25), 1)
            case .UncivBirthday: return span(date(11, 21), 1)
            case .Friday13th:
                let fridays = (1...12).map { date($0, 13) }.filter { cal.component(.weekday, from: $0) == 6 }
                guard !fridays.isEmpty else { return nil }
                // Unciv HolidayDates.kt:105: `.randomOrNull(Random(year))` — Random(Int), `seed == 0 -> 42` kestirmesi yok.
                var rng = SeededRandom(kotlinSeed: Int32(truncatingIfNeeded: year))
                return span(fridays[Int(rng.nextInt(until: Int32(fridays.count)))], 1)
            case .StarWarsDay: return span(date(5, 4), 1)
            case .Passover:
                guard let offset = HolidayDates.passover[year] else { return nil }
                return span(cal.date(byAdding: .day, value: offset - 2, to: date(4, 1))!, 5)
            }
        }
    }

    static let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }()
    private static func closestWeekday(_ d: Date, weekday: Int) -> Date {
        let delta = (7 + calendar.component(.weekday, from: d) - weekday) % 7
        return calendar.date(byAdding: .day, value: delta < 4 ? delta : delta - 7, to: d)!
    }
    /// Diwali dates (theholidayspot.com), lunar new year as day-of-year, Passover as days after April 1 — Unciv's tables.
    static let diwali: [Int: (Int, Int)] = [2024: (11, 1), 2025: (10, 21), 2026: (11, 8), 2027: (10, 29), 2028: (10, 17), 2029: (11, 5), 2030: (10, 26), 2031: (11, 14), 2032: (11, 2), 2033: (10, 22), 2034: (11, 10), 2035: (10, 20), 2036: (10, 19), 2037: (11, 7), 2038: (10, 27), 2039: (10, 17)]
    static let lunarNewYear: [Int: Int] = [2024: 41, 2025: 29, 2026: 48, 2027: 37, 2028: 26, 2029: 44, 2030: 34, 2031: 23, 2032: 42, 2033: 31, 2034: 50, 2035: 39, 2036: 28, 2037: 46, 2038: 35, 2039: 24]
    static let passover: [Int: Int] = [2023: 5, 2024: 22, 2025: 12, 2026: 1, 2027: 21, 2028: 10, 2029: -2, 2030: 17, 2031: 7, 2032: -6, 2033: 13, 2034: 3, 2035: 23, 2036: 11, 2037: -2, 2038: 19, 2039: 8]

    /// Unciv getHolidayByDate: the `easterEgg` launch argument overrides; otherwise the first holiday whose range contains today and whose chance rolls.
    static func holiday(on date: Date = Date()) -> Holiday? {
        if let i = CommandLine.arguments.firstIndex(of: "--easterEgg"), i + 1 < CommandLine.arguments.count, let h = Holiday(rawValue: CommandLine.arguments[i + 1]) { return h }
        let day = calendar.startOfDay(for: date)
        let year = calendar.component(.year, from: day)
        // Unciv HolidayDates.kt:156: `val rng = Random(date.hashCode())` — java.time.LocalDate.hashCode(),
        // ve :160 `rng.nextFloat() <= it.chance` (nextDouble degil).
        var rng = SeededRandom(kotlinSeed: javaLocalDateHash(year: year,
                                                             month: calendar.component(.month, from: day),
                                                             day: calendar.component(.day, from: day)))
        for h in Holiday.allCases {
            guard let r = h.range(year: year), r.contains(day) else { continue }
            if Double(rng.nextFloat()) <= h.chance { return h }
        }
        return nil
    }
}
