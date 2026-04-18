# Fair Games

A free, open-source collection of classic puzzle and arcade games for iOS and Android, built entirely in SwiftUI with [Skip](https://skip.dev).

Every game is written in 100% SwiftUI. The Swift code runs natively on iOS via Xcode, and Skip transpiles it to Kotlin and Jetpack Compose for Android. There is no platform-specific code in any of the game modules -- the same SwiftUI views, gestures, and animations power both platforms.

Fair Games is distributed through the [App Fair](https://appfair.org).

## Architecture

The project is a Swift Package Manager package with a modular structure. Each game is a self-contained SwiftPM library target with no dependencies on the other games:

```
FaireGames           App shell, game hub, navigation
FaireGamesModel      Shared preferences (e.g., beta flags)
BlockBlast           Block Blast game module
Tetris               Sirtet (Tetris) game module
FlappyBird           Flappy Bird game module
Breakout             Breakout game module
Sudoku               Sudoku game module
TwentyFortyEight     2048 game module
```

Each game module contains:

- A single Swift source file with the game model (`@Observable`), SwiftUI views, settings, and preview icon
- A `Skip/skip.yml` configuration for Android transpilation
- Symbol assets in `Resources/Module.xcassets` (using Google Material Symbols in Apple symbolset format for cross-platform consistency)
- A test target with unit tests and a Kotlin transpilation parity test (`XCSkipTests`)

All games share these patterns:

- **State persistence** -- Game state is serialized to JSON and stored in UserDefaults, so progress survives app exits and background kills
- **Haptic feedback** -- Custom haptic patterns via SkipKit's `HapticFeedback` API, with per-game intensity tuning and a vibration toggle in settings
- **Pause menu** -- A consistent pause overlay with Resume, New Game, Settings, and Quit Game, using `.borderedProminent` button styling
- **High score tracking** -- Persisted via UserDefaults with animated score displays
- **Dark theme** -- All games use dark backgrounds for comfortable play

## Games

<img height="500" alt="Faire-Games Android" src="https://raw.githubusercontent.com/Faire-Games/Faire-Games/refs/heads/main/Android/fastlane/metadata/android/en-US/images/phoneScreenshots/1_en-US.png" /><img height="500" alt="Faire-Games iOS" src="https://raw.githubusercontent.com/Faire-Games/Faire-Games/refs/heads/main/Darwin/fastlane/screenshots/en-US/1_en-US.png" />

### Block Blast

Drop and arrange colorful block shapes onto an 8x8 grid. Fill complete rows or columns to clear them and score points. Build combos by clearing multiple lines in a row. Clearing the entire board awards a 200-point bonus. The score display animates with a satisfying spin-up curve.

<img height="500" alt="Faire-Games Block Blast Android" src="https://raw.githubusercontent.com/Faire-Games/Faire-Games/refs/heads/main/Android/fastlane/metadata/android/en-US/images/phoneScreenshots/2_en-US.png" /><img height="500" alt="Faire-Games Block Blast iOS" src="https://raw.githubusercontent.com/Faire-Games/Faire-Games/refs/heads/main/Darwin/fastlane/screenshots/en-US/2_en-US.png" />

### Sirtet

The classic falling-block game. Guide tetrominoes as they fall, rotate them into place, and clear lines to level up. Uses the 7-piece randomization bag system. Speed increases with each level. Swipe to move, tap to rotate, swipe down to drop.

<img height="500" alt="Faire-Games Sirtet Android" src="https://raw.githubusercontent.com/Faire-Games/Faire-Games/refs/heads/main/Android/fastlane/metadata/android/en-US/images/phoneScreenshots/3_en-US.png" /><img height="500" alt="Faire-Games Sirtet iOS" src="https://raw.githubusercontent.com/Faire-Games/Faire-Games/refs/heads/main/Darwin/fastlane/screenshots/en-US/3_en-US.png" />

### Flappy Bird

Tap to flap and navigate a bird through an endless series of pipe obstacles. Features animated wing flapping, procedural pipe generation, and adjustable difficulty (1-10) that controls gravity, flap velocity, pipe speed, gap size, and spacing.

<img height="500" alt="Faire-Games Flappy Bird Android" src="https://raw.githubusercontent.com/Faire-Games/Faire-Games/refs/heads/main/Android/fastlane/metadata/android/en-US/images/phoneScreenshots/4_en-US.png" /><img height="500" alt="Faire-Games Flappy Bird iOS" src="https://raw.githubusercontent.com/Faire-Games/Faire-Games/refs/heads/main/Darwin/fastlane/screenshots/en-US/4_en-US.png" />

### Breakout

Bounce a ball off a paddle to smash through rows of rainbow-colored bricks. The ball's reflection angle depends on where it hits the paddle. Haptic feedback varies with the deflection angle -- direct returns feel heavy, glancing hits feel light. Levels get progressively faster.

<img height="500" alt="Faire-Games Breakout Android" src="https://raw.githubusercontent.com/Faire-Games/Faire-Games/refs/heads/main/Android/fastlane/metadata/android/en-US/images/phoneScreenshots/5_en-US.png" /><img height="500" alt="Faire-Games Breakout iOS" src="https://raw.githubusercontent.com/Faire-Games/Faire-Games/refs/heads/main/Darwin/fastlane/screenshots/en-US/5_en-US.png" />

### Sudoku

Fill the 9x9 grid so every row, column, and 3x3 box contains digits 1-9. Four difficulty levels (Easy through Expert), pencil mark notes, an undo/redo system, hints, and a timer tracking best times per difficulty. Puzzles are generated from a canonical solution with structure-preserving random transformations.

<img height="500" alt="Faire-Games Sudoku Android" src="https://raw.githubusercontent.com/Faire-Games/Faire-Games/refs/heads/main/Android/fastlane/metadata/android/en-US/images/phoneScreenshots/6_en-US.png" /><img height="500" alt="Faire-Games Sudoku iOS" src="https://raw.githubusercontent.com/Faire-Games/Faire-Games/refs/heads/main/Darwin/fastlane/screenshots/en-US/6_en-US.png" />

### 2048

Swipe to slide numbered tiles across a 4x4 board. Matching tiles merge and double in value. Reach 2048 to win, then keep going for higher scores. Features merge-pop and tile-appear scale animations, and escalating haptic patterns from gentle ticks for small merges up to a full celebratory haptic melody when reaching 2048.

<img height="500" alt="Faire-Games 2048 Android" src="https://raw.githubusercontent.com/Faire-Games/Faire-Games/refs/heads/main/Android/fastlane/metadata/android/en-US/images/phoneScreenshots/7_en-US.png" /><img height="500" alt="Faire-Games 2048 iOS" src="https://raw.githubusercontent.com/Faire-Games/Faire-Games/refs/heads/main/Darwin/fastlane/screenshots/en-US/7_en-US.png" />

## Building

This project is both a stand-alone Swift Package Manager module and an Xcode project that builds and translates the project into a Kotlin Gradle project for Android using the Skip transpiler.

```bash
swift build       # Build Swift (does not check Kotlin)
swift test        # Run Swift tests + Kotlin transpilation + JVM tests
```

## Running

Xcode and Android Studio must be installed to run the app in the iOS simulator and Android emulator. An Android emulator must already be running (launch from Android Studio's Device Manager).

Open `Project.xcworkspace` in Xcode and run the "FaireGames App" target to launch both the iOS and Android apps simultaneously. The build phase deploys the Skip app to the running Android emulator or connected device.

- iOS logs: Xcode console
- Android logs: Android Studio logcat or `adb logcat`

## Testing

```bash
swift test                                          # All tests (Swift + Kotlin)
swift test --filter BlockBlastTests                  # Single game tests
swift test --filter TwentyFortyEightTests/saveAndRestoreState  # Single test method
```

Each game module has tests for basic functionality, JSON resource decoding, and a save/restore state round-trip test that verifies game state serialization. The `XCSkipTests` target in each module transpiles all source to Kotlin, compiles with Gradle, and runs the full test suite on the JVM.

## License

This software is licensed under the [GNU General Public License v2.0 or later](https://spdx.org/licenses/GPL-2.0-or-later.html).
