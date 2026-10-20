// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `models/ruleset/unique/expressions/Expressions.kt`: the countable that accepts arithmetic
/// over numbers and `[countable]` terms, e.g. `([[Melee] Units] + 1) / [Cities]`.
enum CountableExpression {
    /// Parse and evaluate an expression. The `[countable]` terms are resolved through `resolve` as they are read.
    static func eval(_ text: String, resolve: (String) -> Int?) -> Int? {
        guard let tokens = tokenize(text, resolve: resolve), !tokens.isEmpty else { return nil }
        return parse(tokens)
    }
}
