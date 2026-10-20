// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv TranslationFileReader: reads a `.properties` translation file - `key = value` lines, `#` comments and
/// blank lines skipped, `\n` unescaped in both halves.
extension Translations {
    /// Unciv TranslationFileReader.read: `forEachLine` - BufferedReader.readLine ends a line at "\n", "\r" or "\r\n".
    /// (Split on the Character "\n" alone, a file with Windows line ends was one line - "\r\n" is a single Character in
    /// Swift - so a mod's Turkish.properties written on Windows translated its first key to the whole rest of the file.)
    static func parseProperties(_ text: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let line = String(raw)
            if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let r = line.range(of: " = ") else { continue }
            let key = String(line[line.startIndex..<r.lowerBound]).replacingOccurrences(of: "\\n", with: "\n")   // multi-line keys (tutorials) are escaped the same way as values
            let value = String(line[r.upperBound...]).replacingOccurrences(of: "\\n", with: "\n")
            out.append((key, value))
        }
        return out
    }
}
