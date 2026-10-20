// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// One parsed Unciv-style unique, e.g. "[+1 Happiness] per [10] population [in all cities] <when below [-10] [Happiness]>".
/// `pattern` has every top-level [param] replaced with "[]" and conditionals removed, so rules can be matched by shape.
struct Unique: Hashable, CustomStringConvertible {
    let text: String
    let pattern: String
    let params: [String]
    let conditionals: [Unique]
    /// Unciv TemporaryUnique.sourceObjectName: what granted this unique, for the first-to-research conditionals.
    var sourceObjectName: String? = nil
    /// Unciv Unique.sourceObjectType: the kind of object it was declared on.
    var sourceObjectType: UniqueTarget? = nil

    var description: String { text }

    /// Unciv IHasUniques: the uniques of an object are stamped with that object as they are read.
    func from(_ type: UniqueTarget, _ name: String? = nil) -> Unique {
        var u = self
        u.sourceObjectType = type
        if let name { u.sourceObjectName = name }
        return u
    }

    /// Unciv Unique.getSourceNameForUser: the heading a stat breakdown files this unique under.
    var sourceNameForUser: String {
        switch sourceObjectType {
        case nil: return ""
        // Unciv `UniqueTarget.Global -> GlobalUniques.getUniqueSourceDescription(this)`: Global alone - the ruleset's global
        // uniques are UniqueTarget.GlobalUniques (GlobalUniques.getUniqueTarget), which falls to `else -> sourceObjectType.name`
        // and so reads "GlobalUniques" (the state dump's CTREE, a test game, turn 39: Adrianople's -50% production under
        // "GlobalUniques > Global Uniques", ours under "Global Effect")
        case .global:
            // Unciv GlobalUniques.getUniqueSourceDescription
            guard let first = conditionals.first else { return "Global Effect" }
            switch first.pattern {
            case "during a Golden Age": return "Golden Age"
            case "while the empire is happy": return "Happiness"
            case "during We Love The King Day": return "We Love The King Day"
            default: return "Global Effect"
            }
        case .wonder: return "Wonders"
        case .building: return "Buildings"
        case .policy: return "Policies"
        case .cityState: return "City-States"
        case .some(let t): return t.rawValue
        }
    }

    init(_ raw: String) {
        text = raw
        var main = ""
        var conds: [Unique] = []
        // Split off <conditionals> (they never nest inside each other).
        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if c == "<" , let close = raw[i...].firstIndex(of: ">") {
                let inner = String(raw[raw.index(after: i)..<close])
                conds.append(Unique(inner))
                i = raw.index(after: close)
            } else { main.append(c); i = raw.index(after: i) }
        }
        conditionals = conds
        // Extract top-level [params], allowing nested brackets like [{Military} {Water}] or [non-[Puppeted]].
        var pat = "", ps: [String] = [], depth = 0, current = ""
        for ch in main {
            if ch == "[" {
                if depth == 0 { current = "" } else { current.append(ch) }
                depth += 1
            } else if ch == "]" {
                depth -= 1
                if depth == 0 { ps.append(current); pat += "[]" } else { current.append(ch) }
            } else if depth > 0 { current.append(ch) } else { pat.append(ch) }
        }
        pattern = pat.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "  ", with: " ")
        params = ps
    }

    /// Unciv Unique.isLocalEffect: the effect belongs to the city that owns the building, written either
    /// as the "[in this city]" parameter or as the "<in this city>" modifier.
    var isLocalEffect: Bool { params.contains("in this city") || conditionals.contains { $0.pattern == "in this city" } }

    /// Same unique with its first (stats) parameter rewritten, e.g. after scaling city-state bonuses.
    func replacingStats(_ st: Stats) -> Unique {
        var parts: [String] = []
        func add(_ v: Double, _ n: String) { if v != 0 { parts.append("\(v >= 0 ? "+" : "")\(v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.1f", v)) \(n)") } }
        add(st.food, "Food"); add(st.production, "Production"); add(st.gold, "Gold"); add(st.science, "Science"); add(st.culture, "Culture"); add(st.faith, "Faith"); add(st.happiness, "Happiness")
        var rebuilt = text
        if let open = text.firstIndex(of: "["), let close = text[open...].firstIndex(of: "]") {
            rebuilt.replaceSubrange(text.index(after: open)..<close, with: parts.joined(separator: ", "))
        }
        return Unique(rebuilt)
    }

    /// The same unique with every `<conditional>` matching `drop` removed (Unciv strips the trigger conditional before activating a triggered unique).
    func withoutConditionals(where drop: (Unique) -> Bool) -> Unique {
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "<", let close = text[i...].firstIndex(of: ">") {
                let inner = String(text[text.index(after: i)..<close])
                if !drop(Unique(inner)) { out += "<" + inner + ">" }
                i = text.index(after: close)
            } else { out.append(text[i]); i = text.index(after: i) }
        }
        return Unique(out.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces))
    }
    func param(_ i: Int) -> String { i < params.count ? params[i] : "" }
    func int(_ i: Int) -> Int { Int(param(i).replacingOccurrences(of: "+", with: "")) ?? 0 }
    func double(_ i: Int) -> Double { Double(param(i).replacingOccurrences(of: "+", with: "")) ?? 0 }

    /// Stats written as "+3 Culture" or "+1 Food, +2 Gold".
    static func parseStats(_ s: String) -> Stats? {
        var stats = Stats(); var any = false
        for part in s.split(separator: ",") {
            let bits = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard bits.count == 2, let v = Double(bits[0].replacingOccurrences(of: "+", with: "")) else { continue }
            any = true
            switch bits[1] {
            case "Food": stats.food += v
            case "Production": stats.production += v
            case "Gold": stats.gold += v
            case "Science": stats.science += v
            case "Culture": stats.culture += v
            case "Happiness": stats.happiness += v
            case "Faith": stats.faith += v
            default: any = false
            }
        }
        return any ? stats : nil
    }
    var stats: Stats? { Unique.parseStats(param(0)) }

    func conditional(_ pattern: String) -> Unique? { conditionals.first { $0.pattern == pattern } }
    func has(_ pattern: String) -> Bool { conditional(pattern) != nil }

    /// "[in capital]" / "[in all cities]" / "[in this city]" style scope, usually the last param.
    var scope: String {
        params.last { $0.hasPrefix("in ") } ?? ""
    }
}

extension Array where Element == String {
    var uniques: [Unique] { map { Unique($0) } }
}

extension Array where Element == Unique {
    /// Unciv IHasUniques.uniqueObjects: every unique of an object carries that object as its source.
    func from(_ type: UniqueTarget, _ name: String? = nil) -> [Unique] { map { $0.from(type, name) } }
}
