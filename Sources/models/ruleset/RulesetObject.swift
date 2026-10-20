// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// One line of Unciv civilopediaText (FormattedLine as read from json): `{"text": …}` plus the attributes that decide
/// where the generated lines go (ICivilopediaText.assembleCivilopediaText: isEmpty, linkType) and how it is drawn.
struct CivilopediaLine: Decodable {
    let text: String
    let link: String?
    let extraImage: String?
    /// FormattedLine.icon / separator / starred / indent / header.
    let icon: String?
    let separator: Bool
    let starred: Bool
    let indent: Int
    let header: Int
    private enum CodingKeys: String, CodingKey { case text, link, extraImage, icon, separator, starred, indent, header }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        link = try c.decodeIfPresent(String.self, forKey: .link)
        extraImage = try c.decodeIfPresent(String.self, forKey: .extraImage)
        icon = try? c.decodeIfPresent(String.self, forKey: .icon)
        separator = (try? c.decodeIfPresent(Bool.self, forKey: .separator)) ?? false
        starred = (try? c.decodeIfPresent(Bool.self, forKey: .starred)) ?? false
        indent = (try? c.decodeIfPresent(Int.self, forKey: .indent)) ?? 0
        header = (try? c.decodeIfPresent(Int.self, forKey: .header)) ?? 0
    }
    /// FormattedLine.isEmpty: nothing to display - no text, image, star, icon, link or separator.
    var isEmpty: Bool { text.isEmpty && (extraImage ?? "").isEmpty && !starred && (icon ?? "").isEmpty && (link ?? "").isEmpty && !separator }
    /// FormattedLine.linkType != None.
    var hasLink: Bool { !(link ?? "").isEmpty }
}
