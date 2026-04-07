// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation

@Observable
public class AppPreferences {
    public var sampleProperty: String = ""

    /// Whether haptic feedback is enabled across all games.
    public var hapticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hapticsEnabled, forKey: "hapticsEnabled")
        }
    }

    /// Level preference for JewelCrush: "both", "untimed", or "timed".
    public var levelPreference: String {
        didSet {
            UserDefaults.standard.set(levelPreference, forKey: "levelPreference")
        }
    }

    /// Whether to show beta (work-in-progress) games.
    public var showBetaGames: Bool {
        didSet {
            UserDefaults.standard.set(showBetaGames, forKey: "showBetaGames")
        }
    }

    public init() {
        // Default to true if the key has never been set
        if UserDefaults.standard.object(forKey: "hapticsEnabled") == nil {
            self.hapticsEnabled = true
        } else {
            self.hapticsEnabled = UserDefaults.standard.bool(forKey: "hapticsEnabled")
        }
        self.levelPreference = UserDefaults.standard.string(forKey: "levelPreference") ?? "both"
        self.showBetaGames = UserDefaults.standard.bool(forKey: "showBetaGames")
    }
}
