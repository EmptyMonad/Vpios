// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv IdChecker: whether a Game- or Player-ID is in the old format (a bare UUID, returned as it is) or the new one
/// (`P-<uuid>-<checkDigit>` / `G-<uuid>-<checkDigit>`, prefix and check digit verified, the UUID returned), or an
/// Unciv deep link (`https://yairm210.github.io/Unciv/P/<id>?name=...`). All input is trimmed first.
enum IdChecker {
    static let uncivUrlPrefix = "https://yairm210.github.io/Unciv/"

    static func isGameDeepLink(_ url: String) -> Bool { hasPrefixIgnoringCase(url, uncivUrlPrefix + "G/") }
    static func isFriendDeepLink(_ url: String) -> Bool { hasPrefixIgnoringCase(url, uncivUrlPrefix + "P/") }

    /// Unciv FriendList.Friend as IdChecker returns it: the link's `name` parameter (empty for a bare id) and the UUID.
    struct Friend { let name: String; let playerID: String }

    /// Unciv checkAndReturnPlayerUuid
    static func checkAndReturnPlayerUuid(_ playerId: String) -> Friend? { checkAndReturnId(playerId, prefix: "P") }
    /// Unciv checkAndReturnUuiId(gameId): a game ID ("G-" prefix)
    static func checkAndReturnUuiId(_ gameId: String) -> String? { checkAndReturnId(gameId, prefix: "G")?.playerID }

    /// Unciv `IdChecker.checkAndReturnPlayerUuid(id)?.playerID?.isUUID() ?: false` - the test PlayerPickerTable's ✔/✘
    /// mark and NewGameScreen.getErrorMessage's "Invalid player ID!" both make
    static func isValidPlayerId(_ id: String) -> Bool { checkAndReturnPlayerUuid(id).map { isUUID($0.playerID) } ?? false }

    private static func checkAndReturnId(_ id: String, prefix: String) -> Friend? {
        let trimmedId = trimSpaceOrWrapper(id)
        if hasPrefixIgnoringCase(trimmedId, uncivUrlPrefix) { return checkAndReturnIdFromUrl(trimmedId, prefix: prefix) }
        return checkAndReturnUuiId(trimmedId, prefix: prefix).map { Friend(name: "", playerID: $0) }
    }

    /// Unciv checkAndReturnIdFromUrl: "http://unciv.app/G/G-2ddb3a34-0699-4126-b7a5-38603e665928-2" style links - three
    /// path segments ("Unciv", the prefix, the id), the `name` query parameter as the friend's name
    private static func checkAndReturnIdFromUrl(_ id: String, prefix: String) -> Friend? {
        guard let url = URLComponents(string: id) else { return nil }
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true).map { $0.removingPercentEncoding ?? String($0) }
        guard segments.count == 3 else { return nil }
        guard segments[0].caseInsensitiveCompare("Unciv") == .orderedSame else { return nil }
        guard segments[1].caseInsensitiveCompare(prefix) == .orderedSame else { return nil }
        guard let gameId = checkAndReturnUuiId(segments[2], prefix: prefix) else { return nil }
        let name = url.queryItems?.first(where: { $0.name == "name" })?.value ?? ""
        return Friend(name: name, playerID: gameId)
    }

    /// Unciv checkAndReturnUuiId(id, prefix): 40 characters is the new format (prefix, check digit, UUID), 36 a bare
    /// UUID; lengths are Java String lengths (UTF-16 units)
    private static func checkAndReturnUuiId(_ id: String, prefix: String) -> String? {
        let trimmedPlayerId = trimSpaceOrWrapper(id)
        let units = Array(trimmedPlayerId.utf16)
        if units.count == 40 {   // length of a UUID (36) with pre- and postfix
            if !hasPrefixIgnoringCase(trimmedPlayerId, prefix) { return nil }
            let checkDigit = String(decoding: units[39..<40], as: UTF16.self)
            // remember, the format is: P-9e37e983-a676-4ecc-800e-ef8ec721a9b9-5
            let shortenedPlayerId = String(decoding: units[2..<38], as: UTF16.self)
            guard let calculated = getCheckDigit(shortenedPlayerId), String(calculated) == checkDigit else { return nil }
            if !isUUID(shortenedPlayerId) { return nil }
            return shortenedPlayerId
        } else if units.count == 36 {
            if !isUUID(trimmedPlayerId) { return nil }
            return trimmedPlayerId
        }
        return nil
    }

    /// Unciv getCheckDigit (the OpenMRS check digit algorithm)
    static func getCheckDigit(_ uuid: String) -> Int? {
        // allowable characters within identifier
        let validChars = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVYWXZ-".utf16)
        // remove leading or trailing whitespace, convert to uppercase
        let idWithoutCheckdigit = Array(uuid.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(with: Locale(identifier: "en")).utf16)
        var sum = 0
        // loop through digits from right to left
        for i in idWithoutCheckdigit.indices {
            let ch = idWithoutCheckdigit[idWithoutCheckdigit.count - i - 1]
            if !validChars.contains(ch) { return nil }
            // our "digit" is calculated using ASCII value - 48
            let digit = Int(ch) - 48
            // alternating digits starting with the rightmost are doubled (digits summed); the others count as they are
            let weight = i % 2 == 0 ? (2 * digit) - (digit / 5) * 9 : digit
            sum += weight
        }
        // avoid sum less than 10 (if characters below "0" allowed, this could happen)
        sum = abs(sum) + 10
        // check digit is amount needed to reach next number divisible by ten
        return (10 - (sum % 10)) % 10
    }

    /// Unciv utils isUUID: java.util.UUID.fromString succeeds
    static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    /// Unciv spaceOrWrapperPredicate: spaces, brackets, quotation marks, other punctuation (periods, commas...) and
    /// control characters (newlines) - not hyphens or connectors - by the Java type of each UTF-16 unit
    private static func trimSpaceOrWrapper(_ s: String) -> String {
        let units = Array(s.utf16)
        func trimmed(_ u: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(u) else { return false }   // a surrogate half: Character.SURROGATE
            switch scalar.properties.generalCategory {
            case .spaceSeparator, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation, .control: return true
            default: return false
            }
        }
        var start = 0, end = units.count
        while start < end && trimmed(units[start]) { start += 1 }
        while end > start && trimmed(units[end - 1]) { end -= 1 }
        return String(decoding: units[start..<end], as: UTF16.self)
    }

    private static func hasPrefixIgnoringCase(_ s: String, _ prefix: String) -> Bool {
        s.lowercased().hasPrefix(prefix.lowercased())
    }
}
