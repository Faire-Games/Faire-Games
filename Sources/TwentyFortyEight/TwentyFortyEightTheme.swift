// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// A color palette for the 2048 game. Defines every color the game's view layer
/// paints: window background, board frame, empty cells, score boxes, HUD text,
/// the per-value tile colors, and the tile text foregrounds. Six themes ship —
/// three light, three dark — and the user picks one from the Settings sheet.
public struct TwentyFortyEightTheme: Identifiable, Hashable, Sendable {
    public let id: String
    public let isDark: Bool

    public let background: Color
    public let boardBackground: Color
    public let emptyCellBackground: Color
    public let emptyCellOpacity: Double
    public let hudForeground: Color
    public let hudBackground: Color
    public let scoreBoxBackground: Color
    public let scoreBoxLabel: Color
    public let scoreBoxValue: Color
    public let lowTileForeground: Color
    public let highTileForeground: Color
    public let tileBeyondColor: Color

    public let tile2: Color
    public let tile4: Color
    public let tile8: Color
    public let tile16: Color
    public let tile32: Color
    public let tile64: Color
    public let tile128: Color
    public let tile256: Color
    public let tile512: Color
    public let tile1024: Color
    public let tile2048: Color

    public func tileColor(for value: Int) -> Color {
        switch value {
        case 2: return tile2
        case 4: return tile4
        case 8: return tile8
        case 16: return tile16
        case 32: return tile32
        case 64: return tile64
        case 128: return tile128
        case 256: return tile256
        case 512: return tile512
        case 1024: return tile1024
        case 2048: return tile2048
        case 0: return emptyCellBackground
        default: return tileBeyondColor
        }
    }

    public func tileForeground(for value: Int) -> Color {
        return value <= 4 ? lowTileForeground : highTileForeground
    }

    /// A condensed palette used by the theme picker preview (5 swatches).
    public var previewSwatches: [Color] {
        return [tile2, tile8, tile32, tile128, tile2048]
    }

    /// Localized display name of this theme. Uses literal `Text` calls so the
    /// xcstrings extractor can see each name as a translatable key.
    public func nameText() -> Text {
        switch id {
        case "classic":  return Text("Classic", bundle: .module, comment: "2048 theme name — the original 2048 palette (beige board, warm orange/yellow tiles)")
        case "sakura":   return Text("Sakura", bundle: .module, comment: "2048 theme name — pink cherry-blossom palette (light theme)")
        case "lagoon":   return Text("Lagoon", bundle: .module, comment: "2048 theme name — bright tropical lagoon blue/teal palette (light theme)")
        case "midnight": return Text("Midnight", bundle: .module, comment: "2048 theme name — dark night-sky palette with neon accents")
        case "forest":   return Text("Forest", bundle: .module, comment: "2048 theme name — dark deep-forest palette with autumn highlights")
        case "ember":    return Text("Ember", bundle: .module, comment: "2048 theme name — dark warm palette evoking glowing embers and firelight")
        default:         return Text("Classic", bundle: .module, comment: "2048 theme name — the original 2048 palette (beige board, warm orange/yellow tiles)")
        }
    }

    public static let classic = TwentyFortyEightTheme(
        id: "classic",
        isDark: false,
        background: Color(red: 0.98, green: 0.97, blue: 0.94),
        boardBackground: Color(red: 0.47, green: 0.43, blue: 0.40),
        emptyCellBackground: Color(red: 0.80, green: 0.76, blue: 0.71),
        emptyCellOpacity: 0.35,
        hudForeground: Color(red: 0.47, green: 0.43, blue: 0.40),
        hudBackground: Color(red: 0.98, green: 0.97, blue: 0.94),
        scoreBoxBackground: Color(red: 0.47, green: 0.43, blue: 0.40),
        scoreBoxLabel: Color(red: 0.93, green: 0.89, blue: 0.85),
        scoreBoxValue: Color.white,
        lowTileForeground: Color(red: 0.47, green: 0.43, blue: 0.40),
        highTileForeground: Color.white,
        tileBeyondColor: Color(red: 0.24, green: 0.23, blue: 0.20),
        tile2:    Color(red: 0.93, green: 0.89, blue: 0.85),
        tile4:    Color(red: 0.93, green: 0.88, blue: 0.78),
        tile8:    Color(red: 0.95, green: 0.69, blue: 0.47),
        tile16:   Color(red: 0.96, green: 0.58, blue: 0.39),
        tile32:   Color(red: 0.96, green: 0.49, blue: 0.37),
        tile64:   Color(red: 0.96, green: 0.37, blue: 0.23),
        tile128:  Color(red: 0.93, green: 0.81, blue: 0.45),
        tile256:  Color(red: 0.93, green: 0.80, blue: 0.38),
        tile512:  Color(red: 0.93, green: 0.78, blue: 0.31),
        tile1024: Color(red: 0.93, green: 0.77, blue: 0.25),
        tile2048: Color(red: 0.93, green: 0.76, blue: 0.18)
    )

    public static let sakura = TwentyFortyEightTheme(
        id: "sakura",
        isDark: false,
        background: Color(red: 0.99, green: 0.95, blue: 0.97),
        boardBackground: Color(red: 0.73, green: 0.45, blue: 0.55),
        emptyCellBackground: Color(red: 0.96, green: 0.85, blue: 0.88),
        emptyCellOpacity: 0.55,
        hudForeground: Color(red: 0.55, green: 0.25, blue: 0.40),
        hudBackground: Color(red: 0.99, green: 0.95, blue: 0.97),
        scoreBoxBackground: Color(red: 0.73, green: 0.45, blue: 0.55),
        scoreBoxLabel: Color(red: 0.99, green: 0.90, blue: 0.93),
        scoreBoxValue: Color.white,
        lowTileForeground: Color(red: 0.55, green: 0.25, blue: 0.40),
        highTileForeground: Color.white,
        tileBeyondColor: Color(red: 0.35, green: 0.10, blue: 0.30),
        tile2:    Color(red: 0.99, green: 0.92, blue: 0.94),
        tile4:    Color(red: 0.99, green: 0.84, blue: 0.89),
        tile8:    Color(red: 0.98, green: 0.70, blue: 0.80),
        tile16:   Color(red: 0.97, green: 0.55, blue: 0.72),
        tile32:   Color(red: 0.94, green: 0.42, blue: 0.62),
        tile64:   Color(red: 0.88, green: 0.30, blue: 0.52),
        tile128:  Color(red: 0.84, green: 0.62, blue: 0.82),
        tile256:  Color(red: 0.75, green: 0.48, blue: 0.78),
        tile512:  Color(red: 0.65, green: 0.36, blue: 0.70),
        tile1024: Color(red: 0.55, green: 0.26, blue: 0.62),
        tile2048: Color(red: 0.46, green: 0.18, blue: 0.52)
    )

    public static let lagoon = TwentyFortyEightTheme(
        id: "lagoon",
        isDark: false,
        background: Color(red: 0.93, green: 0.97, blue: 0.99),
        boardBackground: Color(red: 0.20, green: 0.45, blue: 0.60),
        emptyCellBackground: Color(red: 0.82, green: 0.92, blue: 0.96),
        emptyCellOpacity: 0.55,
        hudForeground: Color(red: 0.10, green: 0.35, blue: 0.50),
        hudBackground: Color(red: 0.93, green: 0.97, blue: 0.99),
        scoreBoxBackground: Color(red: 0.20, green: 0.45, blue: 0.60),
        scoreBoxLabel: Color(red: 0.85, green: 0.95, blue: 0.99),
        scoreBoxValue: Color.white,
        lowTileForeground: Color(red: 0.18, green: 0.38, blue: 0.50),
        highTileForeground: Color.white,
        tileBeyondColor: Color(red: 0.05, green: 0.25, blue: 0.35),
        tile2:    Color(red: 0.92, green: 0.97, blue: 0.99),
        tile4:    Color(red: 0.80, green: 0.92, blue: 0.98),
        tile8:    Color(red: 0.55, green: 0.82, blue: 0.95),
        tile16:   Color(red: 0.35, green: 0.72, blue: 0.93),
        tile32:   Color(red: 0.22, green: 0.62, blue: 0.88),
        tile64:   Color(red: 0.15, green: 0.48, blue: 0.80),
        tile128:  Color(red: 0.40, green: 0.85, blue: 0.85),
        tile256:  Color(red: 0.25, green: 0.75, blue: 0.78),
        tile512:  Color(red: 0.18, green: 0.65, blue: 0.70),
        tile1024: Color(red: 0.12, green: 0.55, blue: 0.62),
        tile2048: Color(red: 0.08, green: 0.45, blue: 0.55)
    )

    public static let midnight = TwentyFortyEightTheme(
        id: "midnight",
        isDark: true,
        background: Color(red: 0.05, green: 0.06, blue: 0.12),
        boardBackground: Color(red: 0.10, green: 0.12, blue: 0.20),
        emptyCellBackground: Color(red: 0.18, green: 0.20, blue: 0.30),
        emptyCellOpacity: 0.60,
        hudForeground: Color(red: 0.85, green: 0.88, blue: 0.96),
        hudBackground: Color(red: 0.05, green: 0.06, blue: 0.12),
        scoreBoxBackground: Color(red: 0.18, green: 0.20, blue: 0.32),
        scoreBoxLabel: Color(red: 0.70, green: 0.75, blue: 0.92),
        scoreBoxValue: Color.white,
        lowTileForeground: Color.white,
        highTileForeground: Color.white,
        tileBeyondColor: Color(red: 1.00, green: 0.97, blue: 0.80),
        tile2:    Color(red: 0.28, green: 0.30, blue: 0.45),
        tile4:    Color(red: 0.34, green: 0.38, blue: 0.62),
        tile8:    Color(red: 0.30, green: 0.50, blue: 0.85),
        tile16:   Color(red: 0.28, green: 0.58, blue: 0.92),
        tile32:   Color(red: 0.50, green: 0.32, blue: 0.88),
        tile64:   Color(red: 0.65, green: 0.30, blue: 0.92),
        tile128:  Color(red: 0.85, green: 0.40, blue: 0.85),
        tile256:  Color(red: 0.95, green: 0.42, blue: 0.72),
        tile512:  Color(red: 1.00, green: 0.55, blue: 0.55),
        tile1024: Color(red: 1.00, green: 0.68, blue: 0.38),
        tile2048: Color(red: 1.00, green: 0.82, blue: 0.25)
    )

    public static let forest = TwentyFortyEightTheme(
        id: "forest",
        isDark: true,
        background: Color(red: 0.05, green: 0.10, blue: 0.07),
        boardBackground: Color(red: 0.10, green: 0.18, blue: 0.13),
        emptyCellBackground: Color(red: 0.18, green: 0.28, blue: 0.20),
        emptyCellOpacity: 0.55,
        hudForeground: Color(red: 0.80, green: 0.92, blue: 0.80),
        hudBackground: Color(red: 0.05, green: 0.10, blue: 0.07),
        scoreBoxBackground: Color(red: 0.16, green: 0.26, blue: 0.18),
        scoreBoxLabel: Color(red: 0.70, green: 0.88, blue: 0.70),
        scoreBoxValue: Color.white,
        lowTileForeground: Color.white,
        highTileForeground: Color.white,
        tileBeyondColor: Color(red: 1.00, green: 0.95, blue: 0.70),
        tile2:    Color(red: 0.22, green: 0.38, blue: 0.28),
        tile4:    Color(red: 0.30, green: 0.50, blue: 0.35),
        tile8:    Color(red: 0.36, green: 0.62, blue: 0.40),
        tile16:   Color(red: 0.45, green: 0.72, blue: 0.42),
        tile32:   Color(red: 0.58, green: 0.80, blue: 0.40),
        tile64:   Color(red: 0.72, green: 0.85, blue: 0.36),
        tile128:  Color(red: 0.88, green: 0.82, blue: 0.32),
        tile256:  Color(red: 0.95, green: 0.72, blue: 0.28),
        tile512:  Color(red: 0.96, green: 0.58, blue: 0.22),
        tile1024: Color(red: 0.97, green: 0.45, blue: 0.18),
        tile2048: Color(red: 0.98, green: 0.32, blue: 0.14)
    )

    public static let ember = TwentyFortyEightTheme(
        id: "ember",
        isDark: true,
        background: Color(red: 0.10, green: 0.05, blue: 0.10),
        boardBackground: Color(red: 0.22, green: 0.10, blue: 0.20),
        emptyCellBackground: Color(red: 0.32, green: 0.18, blue: 0.28),
        emptyCellOpacity: 0.55,
        hudForeground: Color(red: 0.99, green: 0.85, blue: 0.78),
        hudBackground: Color(red: 0.10, green: 0.05, blue: 0.10),
        scoreBoxBackground: Color(red: 0.28, green: 0.14, blue: 0.24),
        scoreBoxLabel: Color(red: 0.99, green: 0.78, blue: 0.72),
        scoreBoxValue: Color.white,
        lowTileForeground: Color.white,
        highTileForeground: Color(red: 0.20, green: 0.08, blue: 0.05),
        tileBeyondColor: Color(red: 1.00, green: 1.00, blue: 0.90),
        tile2:    Color(red: 0.42, green: 0.20, blue: 0.36),
        tile4:    Color(red: 0.58, green: 0.24, blue: 0.40),
        tile8:    Color(red: 0.75, green: 0.30, blue: 0.40),
        tile16:   Color(red: 0.88, green: 0.38, blue: 0.35),
        tile32:   Color(red: 0.95, green: 0.50, blue: 0.30),
        tile64:   Color(red: 0.98, green: 0.62, blue: 0.25),
        tile128:  Color(red: 0.99, green: 0.72, blue: 0.25),
        tile256:  Color(red: 0.99, green: 0.82, blue: 0.32),
        tile512:  Color(red: 1.00, green: 0.90, blue: 0.45),
        tile1024: Color(red: 1.00, green: 0.94, blue: 0.62),
        tile2048: Color(red: 1.00, green: 0.97, blue: 0.78)
    )

    public static let all: [TwentyFortyEightTheme] = [
        .classic, .sakura, .lagoon, .midnight, .forest, .ember,
    ]

    public static func theme(forID id: String) -> TwentyFortyEightTheme {
        for t in all {
            if t.id == id { return t }
        }
        return .classic
    }
}
