// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation

nonisolated(unsafe) private let defaults = UserDefaults.standard

private extension UserDefaults {
    func value<T>(forKey key: String, default defaultValue: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? defaultValue
    }
}

/// Top-level preferences for the Fair Games app shell.
///
/// Per-game preferences (vibrations, level filters, hard mode, etc.) live
/// inside each game module as their own observable types — see
/// `BlockBlastPreferences`, `TetrisPreferences`, and `JewelCrushPreferences`.
@Observable
public class GamePreferences {
    /// Whether to show beta (work-in-progress) games on the front screen.
    public var showBetaGames: Bool = defaults.value(forKey: "showBetaGames", default: false) {
        didSet { defaults.set(showBetaGames, forKey: "showBetaGames") }
    }

    /// User-customised order of game tiles on the home screen, stored as the
    /// raw-value identifier of each game. An empty array means "use the
    /// app's default order".
    public var gameOrder: [String] = defaults.value(forKey: "gameOrder", default: [String]()) {
        didSet { defaults.set(gameOrder, forKey: "gameOrder") }
    }

    public init() {
    }
}
