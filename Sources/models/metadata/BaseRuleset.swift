// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv BaseRuleset: the base rulesets the game ships with. Unciv names them in an enum; here they are the
/// ruleset folders the bundle carries, with the default one named.
extension Ruleset {
    static let baseRulesetName = "Civ V - Gods & Kings"
    /// Unciv BaseRuleset: the base rulesets the game ships with.
    static var baseRulesets: [String] {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("GameData/Rulesets"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [baseRulesetName] }
        return names.filter { $0.hasPrefix("Civ V - ") }.sorted()
    }
    /// What the screens show for a base ruleset: its translated name without the leading "Civ V - " (Vanilla, Gods & Kings).
    /// The folder name stays the ruleset's id - saves, maps, mods and "<if [Civ V - Gods & Kings] is enabled>" name it so.
    /// The translations write the prefix their own way: "Civ V ‒ " / "Civ V – " (other dashes), "CIV V - ", "Tamaddon V - ",
    /// "문명 5 - ", "文明5 - ", "सिविलाइजेशन ५ — " and Japanese "シヴィライゼーション 5 （バニラ）" / "… 5 拡張パック「神々と王」".
    static func displayName(translated: String) -> String {
        let t = translated.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^[^-‒–—]{0,24}?(V|5|५)\s*[-‒–—]\s*"#, options: [.regularExpression, .caseInsensitive]) {
            return String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        if let r = t.range(of: #"^\S+\s*5\s*"#, options: .regularExpression) {   // no dash: the name follows the 5
            var rest = String(t[r.upperBound...])
            for (open, close) in [("「", "」"), ("（", "）"), ("(", ")")] {
                if let a = rest.range(of: open), let b = rest.range(of: close, range: a.upperBound..<rest.endIndex) { rest = String(rest[a.upperBound..<b.lowerBound]); break }
            }
            return rest.trimmingCharacters(in: .whitespaces)
        }
        return t
    }
    /// A mod list as the screens show it: a base ruleset that an older Unciv save keeps among its mods under its shown
    /// name (L), the mods' own folder names as they are
    static func shownModList(_ mods: [String]) -> String {
        mods.map { baseRulesets.contains($0) ? L($0) : $0 }.joined(separator: ", ")
    }
}
