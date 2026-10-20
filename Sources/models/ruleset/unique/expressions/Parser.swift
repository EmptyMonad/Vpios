// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `models/ruleset/unique/expressions/Parser.kt`: recursive-descent parsing of a tokenized
/// expression. Unciv builds an AST (`Node`) out of an operator table (`Operator`) and evaluates it afterwards;
/// here the operators are inlined in the grammar and the value is produced while parsing.
extension CountableExpression {
    static func parse(_ tokens: [Token]) -> Int? {
        var i = 0
        func parseExpr() -> Double? {
            guard var v = parseTerm() else { return nil }
            while i < tokens.count, case .op(let o) = tokens[i], o == "+" || o == "-" {
                i += 1; guard let r = parseTerm() else { return nil }
                v = o == "+" ? v + r : v - r
            }
            return v
        }
        func parseTerm() -> Double? {
            guard var v = parseFactor() else { return nil }
            while i < tokens.count, case .op(let o) = tokens[i], o == "*" || o == "/" || o == "%" {
                i += 1; guard let r = parseFactor() else { return nil }
                switch o {
                case "*": v *= r
                // Unciv Operator.BinaryOperators.Division: sifira bolme ifadeyi bozmaz, 0 uretir.
                case "/": v = r == 0 ? 0 : v / r
                // Unciv Operator.BinaryOperators.Remainder: gercek modulo, sonuc hep negatif olmayan.
                default: v = r == 0 ? 0 : ((v.truncatingRemainder(dividingBy: r)) + r).truncatingRemainder(dividingBy: r)
                }
            }
            return v
        }
        func parseFactor() -> Double? {
            guard var v = parseUnary() else { return nil }
            if i < tokens.count, case .op(let o) = tokens[i], o == "^" { i += 1; guard let r = parseFactor() else { return nil }; v = pow(v, r) }
            return v
        }
        func parseUnary() -> Double? {
            guard i < tokens.count else { return nil }
            switch tokens[i] {
            case .op(let o) where o == "-": i += 1; return parseUnary().map { -$0 }
            case .op(let o) where o == "+": i += 1; return parseUnary()
            case .num(let n): i += 1; return n
            case .lparen:
                i += 1; guard let v = parseExpr(), i < tokens.count, case .rparen = tokens[i] else { return nil }
                i += 1; return v
            default: return nil
            }
        }
        guard let v = parseExpr(), i == tokens.count else { return nil }
        // Unciv Expressions.eval: `node.eval(gameContext).roundToInt()` - Kotlin's, which holds a value past Int32 (an
        // infinity too) at Int.MAX_VALUE / Int.MIN_VALUE; `2 ^ [turns]` past turn 63 stopped the app in Swift's Int().
        // A NaN - `(-1) ^ 0.5`, and Unciv's `x % 0`, which ours makes 0 - throws there, uncaught; it is nil here.
        return try? Stats.kotlinRoundToInt(v)
    }
}
