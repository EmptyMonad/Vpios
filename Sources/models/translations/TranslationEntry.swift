// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv TranslationEntry: one translatable string - the original as the game writes it, and its translation.
extension Translations {
    struct Entry { let original: String; let value: String }
}
