// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `models/ruleset/unique/expressions/Tokenizer.kt`: turning the expression text into tokens.
extension CountableExpression {
    enum Token { case num(Double), op(Character), lparen, rparen }

    static func tokenize(_ text: String, resolve: (String) -> Int?) -> [Token]? {
        var out: [Token] = []
        let chars = Array(text)
        var i = 0
        var sawOperator = false
        while i < chars.count {
            let c = chars[i]
            if c == " " { i += 1; continue }
            if c == "[" {
                var depth = 0, j = i
                while j < chars.count { if chars[j] == "[" { depth += 1 } else if chars[j] == "]" { depth -= 1; if depth == 0 { break } }; j += 1 }
                guard j < chars.count else { return nil }
                let inner = String(chars[(i + 1)..<j])
                guard let v = resolve(inner) else { return nil }
                out.append(.num(Double(v))); i = j + 1; continue
            }
            if c.isNumber || c == "." {
                var j = i; while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                guard let v = Double(String(chars[i..<j])) else { return nil }
                out.append(.num(v)); i = j; continue
            }
            if "+-*/%^".contains(c) { out.append(.op(c)); sawOperator = true; i += 1; continue }
            if c == "(" { out.append(.lparen); i += 1; continue }
            if c == ")" { out.append(.rparen); i += 1; continue }
            return nil
        }
        // A bare word is a countable, not an expression; require at least one operator or bracket to count as one.
        return sawOperator || out.count > 1 ? out : (out.count == 1 && text.hasPrefix("[") ? out : nil)
    }
}
