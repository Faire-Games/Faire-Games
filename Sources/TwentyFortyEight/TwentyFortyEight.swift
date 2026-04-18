// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import Observation
import SkipKit

public struct TwentyFortyEightContainerView: View {
    @State private var settings = TwentyFortyEightSettings()

    public init() { }

    public var body: some View {
        TwentyFortyEightGameView()
            .navigationTitle("")
            #if !os(macOS)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .colorScheme(.dark)
            #endif
            .environment(settings)
    }
}

public func resetTwentyFortyEightHighScore() {
    UserDefaults.standard.set(0, forKey: "twentyfortyeight_highscore")
}

// MARK: - Constants

private let gridSize: Int = 4
private let gridSpacing: Double = 6.0
private let tileCornerRadius: Double = 6.0

// Tile colors keyed by value
private let tileColors: [Int: (Double, Double, Double)] = [
    0:    (0.80, 0.76, 0.71),
    2:    (0.93, 0.89, 0.85),
    4:    (0.93, 0.88, 0.78),
    8:    (0.95, 0.69, 0.47),
    16:   (0.96, 0.58, 0.39),
    32:   (0.96, 0.49, 0.37),
    64:   (0.96, 0.37, 0.23),
    128:  (0.93, 0.81, 0.45),
    256:  (0.93, 0.80, 0.38),
    512:  (0.93, 0.78, 0.31),
    1024: (0.93, 0.77, 0.25),
    2048: (0.93, 0.76, 0.18),
]

private func tileColor(for value: Int) -> Color {
    if let c = tileColors[value] {
        return Color(red: c.0, green: c.1, blue: c.2)
    }
    // Values beyond 2048 get a dark color
    return Color(red: 0.24, green: 0.23, blue: 0.20)
}

private func tileForeground(for value: Int) -> Color {
    if value <= 4 {
        return Color(red: 0.47, green: 0.43, blue: 0.40)
    }
    return Color.white
}

private func tileFontSize(for value: Int, cellSize: Double) -> Double {
    if value < 100 { return cellSize * 0.42 }
    if value < 1000 { return cellSize * 0.34 }
    if value < 10000 { return cellSize * 0.28 }
    return cellSize * 0.22
}

// MARK: - Direction

enum Direction {
    case up, down, left, right
}

// MARK: - Saved State

struct TwentyFortyEightSavedState: Codable {
    var grid: [Int]
    var score: Int
    var isGameOver: Bool
    var hasWon: Bool
    var continueAfterWin: Bool
}

// MARK: - Game Model

@Observable
final class TwentyFortyEightModel {
    // Grid stored as flat array [row * gridSize + col], row-major
    var grid: [Int] = Array(repeating: 0, count: gridSize * gridSize)

    var score: Int = 0
    var highScore: Int = UserDefaults.standard.integer(forKey: "twentyfortyeight_highscore")
    var isGameOver: Bool = false
    var hasWon: Bool = false
    var continueAfterWin: Bool = false

    // Animation tracking
    var mergedIndices: [Int] = []
    var spawnedIndex: Int = -1
    private var lineMergePositions: [Int] = []

    func tile(_ row: Int, _ col: Int) -> Int {
        return grid[row * gridSize + col]
    }

    func setTile(_ row: Int, _ col: Int, _ value: Int) {
        grid[row * gridSize + col] = value
    }

    func newGame() {
        grid = Array(repeating: 0, count: gridSize * gridSize)
        score = 0
        isGameOver = false
        hasWon = false
        continueAfterWin = false
        mergedIndices = []
        spawnedIndex = -1
        spawnTile()
        spawnTile()
    }

    func spawnTile() {
        var empties: [Int] = []
        for i in 0..<(gridSize * gridSize) {
            if grid[i] == 0 {
                empties.append(i)
            }
        }
        guard !empties.isEmpty else { return }
        let idx = empties[Int.random(in: 0..<empties.count)]
        grid[idx] = Double.random(in: 0.0...1.0) < 0.9 ? 2 : 4
        spawnedIndex = idx
    }

    func move(_ direction: Direction) -> Bool {
        let before = grid
        let scoreBefore = score
        mergedIndices = []

        switch direction {
        case .left:
            for r in 0..<gridSize {
                let row = extractRow(r)
                let merged = mergeLine(row)
                setRow(r, merged)
                for pos in lineMergePositions {
                    mergedIndices.append(r * gridSize + pos)
                }
            }
        case .right:
            for r in 0..<gridSize {
                let row = extractRow(r)
                let merged = mergeLine(row.reversed()).reversed()
                setRow(r, Array(merged))
                for pos in lineMergePositions {
                    mergedIndices.append(r * gridSize + (gridSize - 1 - pos))
                }
            }
        case .up:
            for c in 0..<gridSize {
                let col = extractCol(c)
                let merged = mergeLine(col)
                setCol(c, merged)
                for pos in lineMergePositions {
                    mergedIndices.append(pos * gridSize + c)
                }
            }
        case .down:
            for c in 0..<gridSize {
                let col = extractCol(c)
                let merged = mergeLine(col.reversed()).reversed()
                setCol(c, Array(merged))
                for pos in lineMergePositions {
                    mergedIndices.append((gridSize - 1 - pos) * gridSize + c)
                }
            }
        }

        let moved = grid != before || score != scoreBefore
        return moved
    }

    private func extractRow(_ r: Int) -> [Int] {
        var result: [Int] = []
        for c in 0..<gridSize {
            result.append(tile(r, c))
        }
        return result
    }

    private func setRow(_ r: Int, _ values: [Int]) {
        for c in 0..<gridSize {
            setTile(r, c, values[c])
        }
    }

    private func extractCol(_ c: Int) -> [Int] {
        var result: [Int] = []
        for r in 0..<gridSize {
            result.append(tile(r, c))
        }
        return result
    }

    private func setCol(_ c: Int, _ values: [Int]) {
        for r in 0..<gridSize {
            setTile(r, c, values[r])
        }
    }

    // Slide non-zeros left, merge adjacent equal pairs, slide again
    private func mergeLine(_ line: [Int]) -> [Int] {
        lineMergePositions = []

        // Remove zeros
        var compact: [Int] = []
        for v in line {
            if v != 0 { compact.append(v) }
        }

        // Merge
        var merged: [Int] = []
        var skip = false
        for i in 0..<compact.count {
            if skip { skip = false; continue }
            if i + 1 < compact.count && compact[i] == compact[i + 1] {
                let val = compact[i] * 2
                let mergePos = merged.count
                merged.append(val)
                score += val
                lineMergePositions.append(mergePos)
                skip = true
            } else {
                merged.append(compact[i])
            }
        }

        // Pad with zeros
        while merged.count < gridSize {
            merged.append(0)
        }
        return merged
    }

    func checkGameState() {
        // Check for 2048 win
        if !continueAfterWin {
            for v in grid {
                if v >= 2048 {
                    hasWon = true
                    saveHighScore()
                    return
                }
            }
        }

        // Check for any empty cell
        for v in grid {
            if v == 0 { return }
        }

        // Check for any possible merge
        for r in 0..<gridSize {
            for c in 0..<gridSize {
                let v = tile(r, c)
                if c + 1 < gridSize && tile(r, c + 1) == v { return }
                if r + 1 < gridSize && tile(r + 1, c) == v { return }
            }
        }

        // No moves left
        isGameOver = true
        saveHighScore()
    }

    func continueGame() {
        continueAfterWin = true
        hasWon = false
    }

    func saveHighScore() {
        if score > highScore {
            highScore = score
            UserDefaults.standard.set(highScore, forKey: "twentyfortyeight_highscore")
        }
    }

    // MARK: - State Persistence

    func makeSavedState() -> TwentyFortyEightSavedState {
        return TwentyFortyEightSavedState(
            grid: grid,
            score: score,
            isGameOver: isGameOver,
            hasWon: hasWon,
            continueAfterWin: continueAfterWin
        )
    }

    func restoreState(_ state: TwentyFortyEightSavedState) {
        grid = state.grid
        score = state.score
        isGameOver = state.isGameOver
        hasWon = state.hasWon
        continueAfterWin = state.continueAfterWin
        highScore = UserDefaults.standard.integer(forKey: "twentyfortyeight_highscore")
        mergedIndices = []
        spawnedIndex = -1
    }

    func saveState() {
        guard let data = try? JSONEncoder().encode(makeSavedState()) else { return }
        guard let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: "twentyfortyeight_saved_state")
    }

    static func loadSavedState() -> TwentyFortyEightSavedState? {
        guard let json = UserDefaults.standard.string(forKey: "twentyfortyeight_saved_state") else { return nil }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TwentyFortyEightSavedState.self, from: data)
    }

    static func clearSavedState() {
        UserDefaults.standard.removeObject(forKey: "twentyfortyeight_saved_state")
    }
}

// MARK: - Game View

struct TwentyFortyEightGameView: View {
    @State private var game = TwentyFortyEightModel()
    @State private var showSettings = false
    @State private var tileScales: [Double] = Array(repeating: 1.0, count: gridSize * gridSize)
    @State private var animTimer: Timer? = nil
    @Environment(\.dismiss) var dismiss
    @Environment(TwentyFortyEightSettings.self) var settings: TwentyFortyEightSettings

    func playHaptic(_ pattern: HapticPattern) {
        if settings.vibrations {
            HapticFeedback.play(pattern)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let boardSize = min(geo.size.width - 32.0, geo.size.height * 0.55)
            let cellSize = (boardSize - gridSpacing * Double(gridSize + 1)) / Double(gridSize)

            VStack(spacing: 0) {
                // HUD
                hudView
                    .frame(height: 44)

                Spacer()

                // Score row
                HStack(spacing: 12) {
                    scoreBox(label: "SCORE", value: game.score)
                    scoreBox(label: "BEST", value: game.highScore)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

                // Board
                ZStack {
                    // Board background
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(red: 0.47, green: 0.43, blue: 0.40))
                        .frame(width: boardSize, height: boardSize)

                    // Empty cell placeholders
                    VStack(spacing: gridSpacing) {
                        ForEach(0..<gridSize, id: \.self) { r in
                            HStack(spacing: gridSpacing) {
                                ForEach(0..<gridSize, id: \.self) { c in
                                    RoundedRectangle(cornerRadius: tileCornerRadius)
                                        .fill(Color(red: 0.80, green: 0.76, blue: 0.71).opacity(0.35))
                                        .frame(width: cellSize, height: cellSize)
                                }
                            }
                        }
                    }

                    // Tile values
                    VStack(spacing: gridSpacing) {
                        ForEach(0..<gridSize, id: \.self) { r in
                            HStack(spacing: gridSpacing) {
                                ForEach(0..<gridSize, id: \.self) { c in
                                    let index = r * gridSize + c
                                    tileView(value: game.tile(r, c), cellSize: cellSize)
                                        .scaleEffect(game.tile(r, c) > 0 ? tileScales[index] : 1.0)
                                }
                            }
                        }
                    }

                    // Win overlay
                    if game.hasWon {
                        winOverlay(boardSize: boardSize)
                    }

                    // Game over overlay
                    if game.isGameOver {
                        gameOverOverlay(boardSize: boardSize)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            if game.isGameOver || game.hasWon { return }
                            let dx = value.translation.width
                            let dy = value.translation.height
                            let direction: Direction
                            if abs(dx) > abs(dy) {
                                direction = dx > 0.0 ? .right : .left
                            } else {
                                direction = dy > 0.0 ? .down : .up
                            }
                            let moved = game.move(direction)
                            if moved {
                                game.spawnTile()
                                triggerAnimations()
                                playMergeHaptics()
                            }
                            game.checkGameState()
                            if game.isGameOver {
                                playHaptic(.impact)
                            }
                            game.saveState()
                        }
                )

                Spacer()

                // New Game button
                Button(action: {
                    TwentyFortyEightModel.clearSavedState()
                    game.newGame()
                    resetScales()
                    playHaptic(.snap)
                }) {
                    Text("New Game")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                        .frame(width: 160, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(red: 0.55, green: 0.47, blue: 0.40))
                        )
                }
                .buttonStyle(.plain)
                .padding(.bottom, 20)

                Spacer()
            }
            .background(Color(red: 0.98, green: 0.97, blue: 0.94).ignoresSafeArea())
        }
        .navigationBarBackButtonHidden()
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear {
            if let state = TwentyFortyEightModel.loadSavedState() {
                game.restoreState(state)
            } else {
                game.newGame()
            }
            resetScales()
        }
        .onDisappear {
            animTimer?.invalidate()
            animTimer = nil
        }
        .sheet(isPresented: $showSettings) {
            TwentyFortyEightSettingsView(settings: settings)
        }
    }

    // MARK: - Animation

    func resetScales() {
        animTimer?.invalidate()
        animTimer = nil
        for i in 0..<(gridSize * gridSize) {
            tileScales[i] = 1.0
        }
    }

    func triggerAnimations() {
        animTimer?.invalidate()

        // Phase 1: set exaggerated starting values (renders this frame)
        for idx in game.mergedIndices {
            tileScales[idx] = 1.2
        }
        if game.spawnedIndex >= 0 && game.spawnedIndex < gridSize * gridSize {
            tileScales[game.spawnedIndex] = 0.1
        }

        // Phase 2: after one frame, animate back to 1.0
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: false) { _ in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) {
                for i in 0..<(gridSize * gridSize) {
                    tileScales[i] = 1.0
                }
            }
        }
    }

    // MARK: - Merge Haptics

    func playMergeHaptics() {
        guard settings.vibrations else { return }

        // Collect merged values from the grid
        var mergedValues: [Int] = []
        for idx in game.mergedIndices {
            mergedValues.append(game.grid[idx])
        }

        // No merges — just a slide, play a punchy snap
        if mergedValues.isEmpty {
            HapticFeedback.play(.place)
            return
        }

        // Sort ascending so we can iterate from the end (largest first)
        mergedValues.sort()

        // Check if any merge reached 2048+ — play the win song
        if mergedValues[mergedValues.count - 1] >= 2048 {
            playWinSong()
            return
        }

        // Build a single pattern: largest merge first, then smaller ones
        var events: [HapticEvent] = []
        var isFirst = true
        var vi = mergedValues.count - 1
        while vi >= 0 {
            let mergeEvents = hapticEventsForMerge(value: mergedValues[vi])
            for j in 0..<mergeEvents.count {
                let e = mergeEvents[j]
                if j == 0 && !isFirst {
                    // Inter-merge gap before this merge's first event
                    events.append(HapticEvent(e.type, intensity: e.intensity, delay: e.delay + 0.1))
                } else {
                    events.append(e)
                }
            }
            isFirst = false
            vi -= 1
        }

        HapticFeedback.play(HapticPattern(events))
    }

    func hapticEventsForMerge(value: Int) -> [HapticEvent] {
        if value <= 4 {
            // 2+2 → 4: punchy tap + tick
            return [
                HapticEvent(.tap, intensity: 0.7),
                HapticEvent(.tick, intensity: 0.5, delay: 0.04),
            ]
        } else if value <= 8 {
            // 4+4 → 8: strong tap + thud kick
            return [
                HapticEvent(.tap, intensity: 0.8),
                HapticEvent(.thud, intensity: 0.5, delay: 0.04),
            ]
        } else if value <= 16 {
            // 8+8 → 16: thud + tap snap
            return [
                HapticEvent(.thud, intensity: 0.7),
                HapticEvent(.tap, intensity: 0.7, delay: 0.04),
            ]
        } else if value <= 32 {
            // 16+16 → 32: heavy thud + tap + tick
            return [
                HapticEvent(.thud, intensity: 0.8),
                HapticEvent(.tap, intensity: 0.8, delay: 0.04),
                HapticEvent(.tick, intensity: 0.6, delay: 0.04),
            ]
        } else if value <= 64 {
            // 32+32 → 64: double thud + tap
            return [
                HapticEvent(.thud, intensity: 0.9),
                HapticEvent(.thud, intensity: 0.7, delay: 0.05),
                HapticEvent(.tap, intensity: 0.8, delay: 0.04),
            ]
        } else if value <= 128 {
            // 64+64 → 128: triple hit
            return [
                HapticEvent(.thud, intensity: 1.0),
                HapticEvent(.tap, intensity: 0.9, delay: 0.04),
                HapticEvent(.thud, intensity: 0.7, delay: 0.05),
                HapticEvent(.tick, intensity: 0.6, delay: 0.04),
            ]
        } else if value <= 256 {
            // 128+128 → 256: rising slam
            return [
                HapticEvent(.rise, intensity: 0.9),
                HapticEvent(.thud, intensity: 1.0, delay: 0.06),
                HapticEvent(.tap, intensity: 0.9, delay: 0.04),
                HapticEvent(.thud, intensity: 0.8, delay: 0.05),
            ]
        } else if value <= 512 {
            // 256+256 → 512: earthquake
            return [
                HapticEvent(.thud, intensity: 1.0),
                HapticEvent(.thud, intensity: 1.0, delay: 0.05),
                HapticEvent(.tap, intensity: 1.0, delay: 0.04),
                HapticEvent(.thud, intensity: 0.9, delay: 0.05),
                HapticEvent(.tick, intensity: 0.7, delay: 0.04),
            ]
        } else if value <= 1024 {
            // 512+512 → 1024: seismic cascade
            return [
                HapticEvent(.thud, intensity: 1.0),
                HapticEvent(.thud, intensity: 1.0, delay: 0.04),
                HapticEvent(.thud, intensity: 1.0, delay: 0.04),
                HapticEvent(.tap, intensity: 1.0, delay: 0.04),
                HapticEvent(.rise, intensity: 1.0, delay: 0.05),
                HapticEvent(.thud, intensity: 1.0, delay: 0.06),
            ]
        } else {
            // 2048+ continuing after win: absolute devastation
            return [
                HapticEvent(.thud, intensity: 1.0),
                HapticEvent(.thud, intensity: 1.0, delay: 0.03),
                HapticEvent(.thud, intensity: 1.0, delay: 0.03),
                HapticEvent(.rise, intensity: 1.0, delay: 0.04),
                HapticEvent(.thud, intensity: 1.0, delay: 0.05),
                HapticEvent(.tap, intensity: 1.0, delay: 0.03),
                HapticEvent(.thud, intensity: 1.0, delay: 0.04),
            ]
        }
    }

    func playWinSong() {
        // Intense celebratory "haptic melody" for reaching 2048
        // Big opener → rapid fire build → massive slam → fireworks → grand finale
        let events: [HapticEvent] = [
            // Opener: three rapid thuds
            HapticEvent(.thud, intensity: 1.0),
            HapticEvent(.thud, intensity: 1.0, delay: 0.06),
            HapticEvent(.thud, intensity: 1.0, delay: 0.06),
            // Ascending rapid-fire build
            HapticEvent(.tap, intensity: 0.7, delay: 0.1),
            HapticEvent(.tap, intensity: 0.8, delay: 0.07),
            HapticEvent(.tap, intensity: 0.9, delay: 0.07),
            HapticEvent(.tap, intensity: 1.0, delay: 0.07),
            // Massive slam
            HapticEvent(.rise, intensity: 1.0, delay: 0.08),
            HapticEvent(.thud, intensity: 1.0, delay: 0.1),
            HapticEvent(.thud, intensity: 1.0, delay: 0.05),
            // Fireworks: rapid sparkle cascade at full power
            HapticEvent(.tick, intensity: 1.0, delay: 0.12),
            HapticEvent(.tap, intensity: 0.9, delay: 0.05),
            HapticEvent(.tick, intensity: 1.0, delay: 0.05),
            HapticEvent(.tap, intensity: 0.8, delay: 0.05),
            HapticEvent(.tick, intensity: 1.0, delay: 0.05),
            HapticEvent(.tap, intensity: 1.0, delay: 0.05),
            // Grand finale: rise → double slam → fall
            HapticEvent(.rise, intensity: 1.0, delay: 0.1),
            HapticEvent(.thud, intensity: 1.0, delay: 0.12),
            HapticEvent(.thud, intensity: 1.0, delay: 0.06),
            HapticEvent(.fall, intensity: 1.0, delay: 0.1),
            // Final punctuation
            HapticEvent(.thud, intensity: 1.0, delay: 0.15),
        ]
        HapticFeedback.play(HapticPattern(events))
    }

    // MARK: - Score Box

    func scoreBox(label: String, value: Int) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(Color(red: 0.93, green: 0.89, blue: 0.85))
            Text("\(value)")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(Color.white)
                .monospaced()
        }
        .frame(minWidth: 80)
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: 0.47, green: 0.43, blue: 0.40))
        )
    }

    // MARK: - Tile

    func tileView(value: Int, cellSize: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: tileCornerRadius)
                .fill(tileColor(for: value))
                .frame(width: cellSize, height: cellSize)

            if value > 0 {
                Text("\(value)")
                    .font(.system(size: tileFontSize(for: value, cellSize: cellSize), weight: .bold, design: .rounded))
                    .foregroundStyle(tileForeground(for: value))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - HUD

    var hudView: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Image("cancel", bundle: .module)
                    .font(.title2)
                    .foregroundStyle(Color(red: 0.47, green: 0.43, blue: 0.40))
            }

            Spacer()

            Text("2048")
                .font(.title)
                .fontWeight(.black)
                .foregroundStyle(Color(red: 0.47, green: 0.43, blue: 0.40))

            Spacer()

            Button(action: { showSettings = true }) {
                Image("settings", bundle: .module)
                    .font(.title2)
                    .foregroundStyle(Color(red: 0.47, green: 0.43, blue: 0.40))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(red: 0.98, green: 0.97, blue: 0.94))
    }

    // MARK: - Win Overlay

    func winOverlay(boardSize: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.93, green: 0.81, blue: 0.45).opacity(0.5))
                .frame(width: boardSize, height: boardSize)

            VStack(spacing: 16) {
                Text("You Win!")
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundStyle(Color.white)

                Text("Score: \(game.score)")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.white)

                Button(action: {
                    game.continueGame()
                }) {
                    Text("Keep Going")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                        .frame(width: 160, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(red: 0.55, green: 0.47, blue: 0.40))
                        )
                }
                .buttonStyle(.plain)

                Button(action: {
                    TwentyFortyEightModel.clearSavedState()
                    game.newGame()
                    resetScales()
                    playHaptic(.snap)
                }) {
                    Text("New Game")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                        .frame(width: 160, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(red: 0.55, green: 0.47, blue: 0.40))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Game Over Overlay

    func gameOverOverlay(boardSize: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.93, green: 0.89, blue: 0.85).opacity(0.7))
                .frame(width: boardSize, height: boardSize)

            VStack(spacing: 16) {
                Text("Game Over!")
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundStyle(Color(red: 0.47, green: 0.43, blue: 0.40))

                VStack(spacing: 4) {
                    Text("Score")
                        .font(.headline)
                        .foregroundStyle(Color(red: 0.47, green: 0.43, blue: 0.40).opacity(0.7))
                    Text("\(game.score)")
                        .font(.system(size: 44))
                        .fontWeight(.bold)
                        .foregroundStyle(Color(red: 0.47, green: 0.43, blue: 0.40))
                        .monospaced()
                }

                if game.score >= game.highScore && game.score > 0 {
                    Text("New High Score!")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(Color(red: 0.95, green: 0.69, blue: 0.47))
                }

                Button(action: {
                    TwentyFortyEightModel.clearSavedState()
                    game.newGame()
                    resetScales()
                    playHaptic(.snap)
                }) {
                    Text("Try Again")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(red: 0.55, green: 0.47, blue: 0.40))
                        )
                }
                .buttonStyle(.plain)

                ShareLink(
                    item: "I scored \(game.score) in 2048 on Faire Games! Can you beat it?\nhttps://appfair.net",
                    subject: Text("2048 Score"),
                    message: Text("I scored \(game.score) in 2048!")
                ) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.subheadline)
                        .foregroundStyle(Color(red: 0.47, green: 0.43, blue: 0.40).opacity(0.7))
                }
            }
        }
    }
}

// MARK: - Preview Icon

public struct TwentyFortyEightPreviewIcon: View {
    public init() { }

    public var body: some View {
        ZStack {
            // Warm background matching the game
            Color(red: 0.98, green: 0.97, blue: 0.94)

            // Board background
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: 0.47, green: 0.43, blue: 0.40))
                .padding(10)

            // Mini grid
            VStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { r in
                    HStack(spacing: 3) {
                        ForEach(0..<4, id: \.self) { c in
                            miniTile(row: r, col: c)
                        }
                    }
                }
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    func miniTile(row: Int, col: Int) -> some View {
        // Show a static arrangement suggesting a 2048 game
        let values = [
            [2, 4, 8, 16],
            [0, 2, 4, 32],
            [0, 0, 2, 64],
            [0, 0, 0, 128],
        ]
        let val = values[row][col]
        return RoundedRectangle(cornerRadius: 2)
            .fill(tileColor(for: val))
            .frame(width: 18, height: 18)
    }
}

// MARK: - Settings

struct TwentyFortyEightSettingsView: View {
    @Bindable var settings: TwentyFortyEightSettings
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("2048") {
                    Toggle("Vibrations", isOn: $settings.vibrations)
                }
                Section("Data") {
                    Button(role: .destructive, action: {
                        resetTwentyFortyEightHighScore()
                    }) {
                        Text("Reset High Score")
                    }
                }
            }
            .navigationTitle("Settings")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

@Observable
public class TwentyFortyEightSettings {
    public var vibrations: Bool = defaults.value(forKey: "twentyfortyeightVibrations", default: true) {
        didSet { defaults.set(vibrations, forKey: "twentyfortyeightVibrations") }
    }

    public init() {
    }
}

nonisolated(unsafe) private let defaults = UserDefaults.standard

private extension UserDefaults {
    func value<T>(forKey key: String, default defaultValue: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? defaultValue
    }
}
