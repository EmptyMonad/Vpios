// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Unciv Player (new-game screen entry): a chosen nation or "Random", human or AI.
struct PlayerSetup: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var chosenCiv: String = "Random"
    var isHuman: Bool = false
    var playerId: String = ""      // Unciv Player.playerId: which online user owns this seat (from the friends list)
    init(chosenCiv: String = "Random", isHuman: Bool = false) { self.chosenCiv = chosenCiv; self.isHuman = isHuman }
    private enum CodingKeys: String, CodingKey { case chosenCiv, isHuman, playerId }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chosenCiv = try c.decodeIfPresent(String.self, forKey: .chosenCiv) ?? "Random"
        isHuman = try c.decodeIfPresent(Bool.self, forKey: .isHuman) ?? false
        playerId = try c.decodeIfPresent(String.self, forKey: .playerId) ?? ""
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chosenCiv, forKey: .chosenCiv); try c.encode(isHuman, forKey: .isHuman); try c.encode(playerId, forKey: .playerId)
    }
}
