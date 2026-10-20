// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `logic/MultiFilter.kt`: implements `and` and `not` logic on top of a single-filter function.
///
/// Syntax:
///   - `and`: `{filter1} {filter2}`... (can repeat as needed)
///   - `not`: `non-[filter]`
enum MultiFilter {
    private static let andPrefix = "{"
    private static let andSeparator = "} {"
    private static let andSuffixChar: Character = "}"
    private static let notPrefix = "non-["
    private static let notSuffix = "]"

    /// - Parameters:
    ///   - input: The complex filtering term
    ///   - filterFunction: The single filter implementation, which receives the term as written
    static func multiFilter(_ input: String, _ filterFunction: (String) -> Bool) -> Bool {
        let f = input.trimmingCharacters(in: .whitespaces)
        if isAnd(f) { return getAndFilters(f).allSatisfy { multiFilter($0, filterFunction) } }
        if isNot(f) { return !multiFilter(getNotFilter(f), filterFunction) }
        return filterFunction(input)
    }

    /// Unciv MultiFilter.isAnd: startsWith('{') && endsWith('}') && contains("} {") —
    /// ayıraç yoksa terim düz bir filtredir, and-filtresi değildir.
    static func isAnd(_ input: String) -> Bool { input.hasPrefix(andPrefix) && input.hasSuffix(String(andSuffixChar)) && input.contains(andSeparator) }

    static func getAndFilters(_ input: String) -> [String] {
        input.split(separator: andSuffixChar)
            .map { $0.replacingOccurrences(of: andPrefix, with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func isNot(_ input: String) -> Bool { input.hasPrefix(notPrefix) && input.hasSuffix(notSuffix) }

    static func getNotFilter(_ input: String) -> String { String(input.dropFirst(notPrefix.count).dropLast(notSuffix.count)) }
}
