// Shell for the Unciv 4X core (MPL-2.0): the app entry point the published source omits.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

@main
struct VPApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .immersiveSystemUI()
        }
    }
}
