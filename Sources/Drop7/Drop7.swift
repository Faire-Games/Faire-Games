// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import Observation
import SkipKit

public struct Drop7ContainerView: View {
    @State private var settings = Drop7Settings()

    public init() { }

    public var body: some View {
        Drop7GameView()
            .navigationTitle("")
            #if !os(macOS)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .colorScheme(.dark)
            #endif
            .environment(settings)
    }
}

public func resetDrop7HighScore() {
    UserDefaults.standard.set(0, forKey: "drop7_highscore")
}

// MARK: - Constants

private let gridCols: Int = 7
private let gridRows: Int = 7
private let cellGap: Double = 4.0
private let discCornerRadius: Double = 6.0

// Cell states
private let stateEmpty: Int = 0
private let stateNormal: Int = 1   // visible numbered disc
private let stateCracked: Int = 2  // value hidden, edges visible
private let stateWrapped: Int = 3  // fully wrapped, value hidden

// Sentinel for "fall source came from below the board" (push-up new bottom row)
private let fallFromBelowSentinel: Int = -2

// Disc colors keyed by value (1..7)
private func discColor(for value: Int) -> Color {
    switch value {
    case 1: return Color(red: 0.86, green: 0.22, blue: 0.22)
    case 2: return Color(red: 0.95, green: 0.55, blue: 0.18)
    case 3: return Color(red: 0.96, green: 0.85, blue: 0.22)
    case 4: return Color(red: 0.34, green: 0.74, blue: 0.32)
    case 5: return Color(red: 0.22, green: 0.52, blue: 0.94)
    case 6: return Color(red: 0.55, green: 0.32, blue: 0.85)
    case 7: return Color(red: 0.95, green: 0.32, blue: 0.66)
    default: return Color(red: 0.5, green: 0.5, blue: 0.5)
    }
}

private func discTextColor(for value: Int) -> Color {
    if value == 3 {
        return Color(red: 0.25, green: 0.20, blue: 0.10)
    }
    return Color.white
}

private let wrappedColor: Color = Color(red: 0.32, green: 0.30, blue: 0.36)
private let crackedColor: Color = Color(red: 0.55, green: 0.50, blue: 0.55)
private let emptyCellColor: Color = Color(red: 0.15, green: 0.15, blue: 0.20)
private let boardBackground: Color = Color(red: 0.10, green: 0.10, blue: 0.16)
private let pageBackground: Color = Color(red: 0.06, green: 0.06, blue: 0.12)

// Chain bonus per chain step (1-indexed)
private let chainBonusTable: [Int] = [7, 39, 109, 224, 391, 617, 907, 1267, 1701, 2213, 2809, 3491, 4257, 5111, 6051]

private func chainBonus(forStep step: Int) -> Int {
    if step <= 0 { return chainBonusTable[0] }
    if step <= chainBonusTable.count {
        return chainBonusTable[step - 1]
    }
    let last = chainBonusTable[chainBonusTable.count - 1]
    return last + (step - chainBonusTable.count) * 1000
}

// MARK: - Difficulty

enum Drop7Difficulty: Int, CaseIterable {
    case easy = 0
    case normal = 1
    case hard = 2

    var label: String {
        switch self {
        case .easy: return "Easy"
        case .normal: return "Normal"
        case .hard: return "Hard"
        }
    }

    var description: String {
        switch self {
        case .easy: return "3 starting rows. New row every 40 drops."
        case .normal: return "5 starting rows. New row every 30 drops."
        case .hard: return "6 starting rows. New row every 25 drops."
        }
    }

    var accentColor: Color {
        switch self {
        case .easy: return Color(red: 0.35, green: 0.75, blue: 0.45)
        case .normal: return Color(red: 0.30, green: 0.60, blue: 0.95)
        case .hard: return Color(red: 0.90, green: 0.35, blue: 0.30)
        }
    }

    var startingRows: Int {
        switch self {
        case .easy: return 3
        case .normal: return 5
        case .hard: return 6
        }
    }

    /// Drops needed to advance to the *first* push-up. Subsequent levels need
    /// progressively fewer drops (see `Drop7Model.currentLevelTarget`).
    var dropsPerLevel: Int {
        switch self {
        case .easy: return 40
        case .normal: return 30
        case .hard: return 25
        }
    }

    /// The minimum number of drops per level once the cadence has decayed.
    var minDropsPerLevel: Int {
        switch self {
        case .easy: return 8
        case .normal: return 5
        case .hard: return 3
        }
    }

    /// Points awarded each time the player completes a level (a push-up fires).
    var levelBonus: Int {
        switch self {
        case .easy: return 5_000
        case .normal: return 7_000
        case .hard: return 14_000
        }
    }
}

// MARK: - Saved State

struct Drop7SavedState: Codable {
    var stateGrid: [Int]
    var valueGrid: [Int]
    var currentPiece: Int
    var nextPiece: Int
    var score: Int
    var dropsThisLevel: Int
    var level: Int
    var isGameOver: Bool
    var difficultyRaw: Int
}

// MARK: - Animation Step Records

struct Drop7ExplosionStep {
    var exploded: [Int]
    var explodedValues: [Int]
    var revealed: [Int]
    var fallSources: [Int]
    var scoreGained: Int
    var stepNumber: Int
    var screenCleared: Bool
}

let drop7ScreenClearBonus: Int = 70_000

struct Drop7AdvanceResult {
    var didPushUp: Bool
    var gameOver: Bool
    var fallSources: [Int]
    var levelBonusGained: Int
}

// MARK: - Game Model

@Observable
final class Drop7Model {
    var stateGrid: [Int] = Array(repeating: 0, count: gridCols * gridRows)
    var valueGrid: [Int] = Array(repeating: 0, count: gridCols * gridRows)

    var currentPiece: Int = 1
    var nextPiece: Int = 1
    var score: Int = 0
    var highScore: Int = UserDefaults.standard.integer(forKey: "drop7_highscore")
    var dropsThisLevel: Int = 0
    var level: Int = 1
    var lastChainCount: Int = 0
    var isGameOver: Bool = false
    var difficulty: Drop7Difficulty = .normal

    func cellIndex(_ row: Int, _ col: Int) -> Int {
        return row * gridCols + col
    }

    func getState(_ row: Int, _ col: Int) -> Int {
        return stateGrid[row * gridCols + col]
    }

    func getValue(_ row: Int, _ col: Int) -> Int {
        return valueGrid[row * gridCols + col]
    }

    func newGame(diff: Drop7Difficulty? = nil) {
        if let d = diff { difficulty = d }
        stateGrid = Array(repeating: 0, count: gridCols * gridRows)
        valueGrid = Array(repeating: 0, count: gridCols * gridRows)
        score = 0
        dropsThisLevel = 0
        level = 1
        lastChainCount = 0
        isGameOver = false

        let startRows = difficulty.startingRows
        var r = gridRows - startRows
        while r < gridRows {
            var c = 0
            while c < gridCols {
                let idx = cellIndex(r, c)
                stateGrid[idx] = stateWrapped
                valueGrid[idx] = Int.random(in: 1...7)
                c += 1
            }
            r += 1
        }
        currentPiece = randomPieceValue()
        nextPiece = randomPieceValue()
    }

    func randomPieceValue() -> Int {
        return Int.random(in: 1...7)
    }

    /// Place currentPiece into the bottom-most empty cell of the given column.
    /// Returns the cell index of the landing position, or -1 if invalid.
    func placePiece(column col: Int) -> Int {
        if isGameOver { return -1 }
        if col < 0 || col >= gridCols { return -1 }
        var landingRow: Int = -1
        var r = gridRows - 1
        while r >= 0 {
            if stateGrid[cellIndex(r, col)] == stateEmpty {
                landingRow = r
                break
            }
            r -= 1
        }
        if landingRow < 0 { return -1 }
        let idx = cellIndex(landingRow, col)
        stateGrid[idx] = stateNormal
        valueGrid[idx] = currentPiece
        return idx
    }

    /// If any cells should explode given the current grid, perform one explosion+settle step.
    /// Returns the step description, or nil if nothing exploded.
    func runOneExplosionStep(stepNumber: Int) -> Drop7ExplosionStep? {
        let exploding = findExploding()
        if exploding.isEmpty { return nil }

        var explodedValues: [Int] = []
        for ex in exploding {
            explodedValues.append(valueGrid[ex])
        }

        let bonus = chainBonus(forStep: stepNumber)
        let gained = bonus * exploding.count
        score += gained

        // Reveal/crack neighbors before clearing
        let explodingSet = Set(exploding)
        var revealed: [Int] = []
        for ex in exploding {
            let er = ex / gridCols
            let ec = ex % gridCols
            let nrs: [Int] = [er - 1, er + 1, er, er]
            let ncs: [Int] = [ec, ec, ec - 1, ec + 1]
            var k = 0
            while k < 4 {
                let nr = nrs[k]
                let nc = ncs[k]
                k += 1
                if nr < 0 || nr >= gridRows || nc < 0 || nc >= gridCols { continue }
                let nidx = cellIndex(nr, nc)
                if explodingSet.contains(nidx) { continue }
                let st = stateGrid[nidx]
                if st == stateWrapped {
                    stateGrid[nidx] = stateCracked
                    revealed.append(nidx)
                } else if st == stateCracked {
                    stateGrid[nidx] = stateNormal
                    revealed.append(nidx)
                }
            }
        }

        // Clear exploded cells
        for ex in exploding {
            stateGrid[ex] = stateEmpty
            valueGrid[ex] = 0
        }

        // Settle with tracking
        let fallSources = settleWithTracking()

        // Screen-clear bonus: if the board is now empty, award the standard 70,000.
        var totalGained = gained
        var cleared = false
        if isBoardEmpty() {
            score += drop7ScreenClearBonus
            totalGained += drop7ScreenClearBonus
            cleared = true
        }

        return Drop7ExplosionStep(
            exploded: exploding,
            explodedValues: explodedValues,
            revealed: revealed,
            fallSources: fallSources,
            scoreGained: totalGained,
            stepNumber: stepNumber,
            screenCleared: cleared
        )
    }

    func isBoardEmpty() -> Bool {
        var i = 0
        while i < stateGrid.count {
            if stateGrid[i] != stateEmpty { return false }
            i += 1
        }
        return true
    }

    private func findExploding() -> [Int] {
        // Drop 7 rule: a disc explodes when its value matches the length of the
        // contiguous run of non-empty cells (including wrapped/cracked) that
        // contains it, in either its row or its column.
        var result: [Int] = []
        var r = 0
        while r < gridRows {
            var c = 0
            while c < gridCols {
                let idx = cellIndex(r, c)
                if stateGrid[idx] == stateNormal {
                    let v = valueGrid[idx]
                    if v == rowRunLength(row: r, col: c) || v == colRunLength(row: r, col: c) {
                        result.append(idx)
                    }
                }
                c += 1
            }
            r += 1
        }
        return result
    }

    private func rowRunLength(row r: Int, col c: Int) -> Int {
        var length = 1
        var cc = c - 1
        while cc >= 0 && stateGrid[cellIndex(r, cc)] != stateEmpty {
            length += 1
            cc -= 1
        }
        cc = c + 1
        while cc < gridCols && stateGrid[cellIndex(r, cc)] != stateEmpty {
            length += 1
            cc += 1
        }
        return length
    }

    private func colRunLength(row r: Int, col c: Int) -> Int {
        var length = 1
        var rr = r - 1
        while rr >= 0 && stateGrid[cellIndex(rr, c)] != stateEmpty {
            length += 1
            rr -= 1
        }
        rr = r + 1
        while rr < gridRows && stateGrid[cellIndex(rr, c)] != stateEmpty {
            length += 1
            rr += 1
        }
        return length
    }

    /// Apply gravity and return per-new-cell mapping of the original (pre-settle) cell index.
    /// fallSources[newIdx] == oldIdx if a disc fell there; -1 if cell is empty (or unchanged but empty).
    private func settleWithTracking() -> [Int] {
        var fallSources: [Int] = Array(repeating: -1, count: gridCols * gridRows)
        var c = 0
        while c < gridCols {
            var keepStates: [Int] = []
            var keepValues: [Int] = []
            var keepIndices: [Int] = []
            var r = gridRows - 1
            while r >= 0 {
                let idx = cellIndex(r, c)
                let st = stateGrid[idx]
                if st != stateEmpty {
                    keepStates.append(st)
                    keepValues.append(valueGrid[idx])
                    keepIndices.append(idx)
                }
                r -= 1
            }
            // Refill column from bottom
            var ri = gridRows - 1
            var i = 0
            while i < keepStates.count {
                let newIdx = cellIndex(ri, c)
                stateGrid[newIdx] = keepStates[i]
                valueGrid[newIdx] = keepValues[i]
                fallSources[newIdx] = keepIndices[i]
                ri -= 1
                i += 1
            }
            while ri >= 0 {
                let idx = cellIndex(ri, c)
                stateGrid[idx] = stateEmpty
                valueGrid[idx] = 0
                ri -= 1
            }
            c += 1
        }
        return fallSources
    }

    /// Drops required to trigger the next push-up at the current level.
    /// In Normal Drop 7 the cadence accelerates: 30 drops, then 29, 28, 27...
    /// down to a per-difficulty floor.
    func currentLevelTarget() -> Int {
        let base = difficulty.dropsPerLevel
        let floor = difficulty.minDropsPerLevel
        let target = base - (level - 1)
        return max(floor, target)
    }

    /// Increment the level counter. If a new level should start, push up.
    /// If nothing changes, returns a no-op result.
    func advanceLevel() -> Drop7AdvanceResult {
        dropsThisLevel += 1
        if dropsThisLevel >= currentLevelTarget() {
            dropsThisLevel = 0
            level += 1
            let bonus = difficulty.levelBonus
            score += bonus
            var result = performPushUp()
            result.levelBonusGained = bonus
            return result
        }
        return Drop7AdvanceResult(didPushUp: false, gameOver: false, fallSources: [], levelBonusGained: 0)
    }

    private func performPushUp() -> Drop7AdvanceResult {
        // Game over if any cell in top row is non-empty (would be pushed off)
        var c = 0
        while c < gridCols {
            if stateGrid[cellIndex(0, c)] != stateEmpty {
                isGameOver = true
                saveHighScore()
                return Drop7AdvanceResult(didPushUp: false, gameOver: true, fallSources: [], levelBonusGained: 0)
            }
            c += 1
        }
        var fallSources: [Int] = Array(repeating: -1, count: gridCols * gridRows)
        var r = 0
        while r < gridRows - 1 {
            var cc = 0
            while cc < gridCols {
                let dst = cellIndex(r, cc)
                let src = cellIndex(r + 1, cc)
                stateGrid[dst] = stateGrid[src]
                valueGrid[dst] = valueGrid[src]
                if stateGrid[dst] != stateEmpty {
                    fallSources[dst] = src
                }
                cc += 1
            }
            r += 1
        }
        let bottom = gridRows - 1
        var c2 = 0
        while c2 < gridCols {
            let idx = cellIndex(bottom, c2)
            stateGrid[idx] = stateWrapped
            valueGrid[idx] = Int.random(in: 1...7)
            fallSources[idx] = fallFromBelowSentinel
            c2 += 1
        }
        return Drop7AdvanceResult(didPushUp: true, gameOver: false, fallSources: fallSources, levelBonusGained: 0)
    }

    func advanceToNextPiece() {
        if !isGameOver {
            currentPiece = nextPiece
            nextPiece = randomPieceValue()
        }
    }

    func canDropAnywhere() -> Bool {
        var c = 0
        while c < gridCols {
            if stateGrid[cellIndex(0, c)] == stateEmpty {
                return true
            }
            c += 1
        }
        return false
    }

    /// Synchronous full drop (used by tests / non-animated path).
    @discardableResult
    func drop(column col: Int) -> Bool {
        let idx = placePiece(column: col)
        if idx < 0 { return false }
        var totalChain = 0
        var step = 1
        while runOneExplosionStep(stepNumber: step) != nil {
            step += 1
            totalChain += 1
        }
        let result = advanceLevel()
        if result.didPushUp && !result.gameOver {
            var s = 1
            while runOneExplosionStep(stepNumber: s) != nil {
                s += 1
                totalChain += 1
            }
        }
        lastChainCount = totalChain
        if !isGameOver && !canDropAnywhere() {
            isGameOver = true
            saveHighScore()
        }
        if !isGameOver {
            advanceToNextPiece()
        }
        saveHighScore()
        return true
    }

    func saveHighScore() {
        if score > highScore {
            highScore = score
            UserDefaults.standard.set(highScore, forKey: "drop7_highscore")
        }
    }

    // MARK: - State Persistence

    func makeSavedState() -> Drop7SavedState {
        return Drop7SavedState(
            stateGrid: stateGrid,
            valueGrid: valueGrid,
            currentPiece: currentPiece,
            nextPiece: nextPiece,
            score: score,
            dropsThisLevel: dropsThisLevel,
            level: level,
            isGameOver: isGameOver,
            difficultyRaw: difficulty.rawValue
        )
    }

    func restoreState(_ s: Drop7SavedState) {
        stateGrid = s.stateGrid
        valueGrid = s.valueGrid
        currentPiece = s.currentPiece
        nextPiece = s.nextPiece
        score = s.score
        dropsThisLevel = s.dropsThisLevel
        level = s.level
        isGameOver = s.isGameOver
        difficulty = Drop7Difficulty(rawValue: s.difficultyRaw) ?? .normal
        highScore = UserDefaults.standard.integer(forKey: "drop7_highscore")
        lastChainCount = 0
    }

    func saveState() {
        guard let data = try? JSONEncoder().encode(makeSavedState()) else { return }
        guard let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: "drop7_saved_state")
    }

    static func loadSavedState() -> Drop7SavedState? {
        guard let json = UserDefaults.standard.string(forKey: "drop7_saved_state") else { return nil }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Drop7SavedState.self, from: data)
    }

    static func clearSavedState() {
        UserDefaults.standard.removeObject(forKey: "drop7_saved_state")
    }
}

// MARK: - Game View

struct Drop7GameView: View {
    @State private var game = Drop7Model()
    @State private var showSettings = false
    @State private var showPauseMenu = false
    @State private var showDifficultyPicker = false
    @State private var hasInitialized = false
    @State private var displayedScore: Int = 0
    @State private var displayedHighScore: Int = 0
    @State private var scoreAnimTimer: Timer? = nil

    // Animation pipeline state
    @State private var isAnimating: Bool = false
    @State private var currentChainStep: Int = 1
    @State private var hasAdvancedThisDrop: Bool = false
    @State private var measuredCellSize: Double = 40.0
    @State private var lastChainShown: Int = 0
    @State private var chainPulse: Double = 0.0
    @State private var turnMaxChain: Int = 0
    @State private var screenClearOpacity: Double = 0.0
    @State private var screenClearScale: Double = 0.5

    // Per-cell animation arrays — sized to gridCols * gridRows (49)
    @State private var cellOffsetY: [Double] = Array(repeating: 0.0, count: gridCols * gridRows)
    @State private var cellScale: [Double] = Array(repeating: 1.0, count: gridCols * gridRows)
    @State private var cellScaleY: [Double] = Array(repeating: 1.0, count: gridCols * gridRows)
    @State private var cellOpacity: [Double] = Array(repeating: 1.0, count: gridCols * gridRows)

    // Ghost layer (renders the disc that's exploding while the model has already cleared it)
    @State private var ghostValue: [Int] = Array(repeating: 0, count: gridCols * gridRows)
    @State private var ghostScale: [Double] = Array(repeating: 0.0, count: gridCols * gridRows)
    @State private var ghostOpacity: [Double] = Array(repeating: 0.0, count: gridCols * gridRows)

    // Burst ring overlay (a colored expanding ring at each exploded position)
    @State private var burstColor: [Int] = Array(repeating: 0, count: gridCols * gridRows)
    @State private var burstScale: [Double] = Array(repeating: 0.0, count: gridCols * gridRows)
    @State private var burstOpacity: [Double] = Array(repeating: 0.0, count: gridCols * gridRows)

    // Reveal pulse (cells that just got cracked or revealed)
    @State private var revealScale: [Double] = Array(repeating: 1.0, count: gridCols * gridRows)

    // Camera shake (for big chains and game over)
    @State private var shakeOffsetX: Double = 0.0

    // Animation timers
    @State private var animTimers: [Timer] = []

    @Environment(\.dismiss) var dismiss
    @Environment(Drop7Settings.self) var settings: Drop7Settings

    func playHaptic(_ pattern: HapticPattern) {
        if settings.vibrations {
            HapticFeedback.play(pattern)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let availableWidth = geo.size.width - 32.0
            let availableHeight = geo.size.height * 0.62
            let cellByWidth = (availableWidth - cellGap * Double(gridCols + 1)) / Double(gridCols)
            let cellByHeight = (availableHeight - cellGap * Double(gridRows + 1)) / Double(gridRows)
            let cellSize = min(cellByWidth, cellByHeight)
            let boardWidth = cellSize * Double(gridCols) + cellGap * Double(gridCols + 1)
            let boardHeight = cellSize * Double(gridRows) + cellGap * Double(gridRows + 1)

            VStack(spacing: 0) {
                hudView
                    .frame(height: 44)

                HStack(spacing: 10) {
                    scoreBox(label: "SCORE", value: displayedScore)
                    levelBox(level: game.level, drops: game.dropsThisLevel, target: game.currentLevelTarget())
                    scoreBox(label: "BEST", value: displayedHighScore)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

                HStack(spacing: 12) {
                    Text("NEXT", bundle: .module)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white.opacity(0.7))

                    miniDisc(value: game.currentPiece, size: 32)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(Color.white.opacity(0.5))
                    miniDisc(value: game.nextPiece, size: 24)

                    Spacer()

                    if lastChainShown >= 2 {
                        Text("Chain x\(lastChainShown)!", bundle: .module)
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.3))
                            .scaleEffect(1.0 + chainPulse * 0.3)
                            .opacity(0.6 + chainPulse * 0.4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                Spacer(minLength: 0)

                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(boardBackground)
                        .frame(width: boardWidth, height: boardHeight)

                    // Cells layer (with offsets/scales)
                    cellsLayer(cellSize: cellSize, boardWidth: boardWidth, boardHeight: boardHeight)

                    // Effects layer (ghost discs + burst rings, not hit-testable)
                    effectsLayer(cellSize: cellSize, boardWidth: boardWidth, boardHeight: boardHeight)
                        .allowsHitTesting(false)

                    // Screen-clear banner
                    if screenClearOpacity > 0.0 {
                        screenClearBanner()
                            .scaleEffect(screenClearScale)
                            .opacity(screenClearOpacity)
                            .allowsHitTesting(false)
                    }

                    if game.isGameOver {
                        gameOverOverlay(width: boardWidth, height: boardHeight)
                    }

                    if showPauseMenu && !game.isGameOver {
                        pauseMenuOverlay(width: boardWidth, height: boardHeight)
                    }
                }
                .offset(x: shakeOffsetX)

                Spacer(minLength: 0)
            }
            .background(pageBackground.ignoresSafeArea())
            .onAppear {
                measuredCellSize = cellSize
            }
            .onChange(of: cellSize) { _, newValue in
                measuredCellSize = newValue
            }
        }
        .navigationBarBackButtonHidden()
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear {
            if !hasInitialized {
                hasInitialized = true
                if let s = Drop7Model.loadSavedState() {
                    game.restoreState(s)
                } else {
                    showDifficultyPicker = true
                }
            }
            displayedScore = game.score
            displayedHighScore = game.highScore
        }
        .onDisappear {
            stopScoreAnimation()
            cancelAllAnimTimers()
        }
        .onChange(of: game.score) { _, _ in startScoreAnimation() }
        .onChange(of: game.highScore) { _, _ in startScoreAnimation() }
        .sheet(isPresented: $showSettings) {
            Drop7SettingsView(settings: settings)
        }
        .sheet(isPresented: $showDifficultyPicker) {
            Drop7DifficultyPickerView { d in
                Drop7Model.clearSavedState()
                cancelAllAnimTimers()
                resetAllAnimationState()
                game.newGame(diff: d)
                stopScoreAnimation()
                displayedScore = 0
                displayedHighScore = game.highScore
                lastChainShown = 0
                showDifficultyPicker = false
                showPauseMenu = false
                isAnimating = false
                playHaptic(.snap)
            }
        }
    }

    // MARK: - Cells layer

    func cellsLayer(cellSize: Double, boardWidth: Double, boardHeight: Double) -> some View {
        HStack(spacing: cellGap) {
            ForEach(0..<gridCols, id: \.self) { c in
                VStack(spacing: cellGap) {
                    ForEach(0..<gridRows, id: \.self) { r in
                        cellView(row: r, col: c, size: cellSize)
                            .onTapGesture {
                                performDrop(column: c)
                            }
                    }
                }
                .padding(.vertical, cellGap)
            }
        }
        .frame(width: boardWidth, height: boardHeight)
    }

    func cellView(row r: Int, col c: Int, size: Double) -> some View {
        let idx = r * gridCols + c
        let st = game.getState(r, c)
        let v = game.getValue(r, c)
        return ZStack {
            RoundedRectangle(cornerRadius: discCornerRadius)
                .fill(emptyCellColor)
                .frame(width: size, height: size)

            if st == stateNormal {
                discContent(value: v, size: size)
                    .scaleEffect(x: cellScale[idx], y: cellScale[idx] * cellScaleY[idx])
                    .opacity(cellOpacity[idx])
            } else if st == stateCracked {
                ZStack {
                    Circle()
                        .fill(crackedColor)
                        .frame(width: size * 0.86, height: size * 0.86)
                    Text("?")
                        .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
                .scaleEffect(revealScale[idx])
            } else if st == stateWrapped {
                Circle()
                    .fill(wrappedColor)
                    .frame(width: size * 0.86, height: size * 0.86)
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(0.4), lineWidth: 1)
                            .frame(width: size * 0.86, height: size * 0.86)
                    )
                    .scaleEffect(revealScale[idx])
            }
        }
        .frame(width: size, height: size)
        .offset(y: cellOffsetY[idx])
    }

    func discContent(value v: Int, size: Double) -> some View {
        ZStack {
            Circle()
                .fill(discColor(for: v))
                .frame(width: size * 0.92, height: size * 0.92)
            // subtle highlight for depth
            Circle()
                .fill(Color.white.opacity(0.18))
                .frame(width: size * 0.5, height: size * 0.5)
                .offset(x: -size * 0.14, y: -size * 0.14)
                .blur(radius: 2)
            Text("\(v)")
                .font(.system(size: size * 0.5, weight: .heavy, design: .rounded))
                .foregroundStyle(discTextColor(for: v))
        }
    }

    // MARK: - Effects layer (ghost discs + burst rings)

    func effectsLayer(cellSize: Double, boardWidth: Double, boardHeight: Double) -> some View {
        HStack(spacing: cellGap) {
            ForEach(0..<gridCols, id: \.self) { c in
                VStack(spacing: cellGap) {
                    ForEach(0..<gridRows, id: \.self) { r in
                        effectCell(row: r, col: c, size: cellSize)
                    }
                }
                .padding(.vertical, cellGap)
            }
        }
        .frame(width: boardWidth, height: boardHeight)
    }

    func effectCell(row r: Int, col c: Int, size: Double) -> some View {
        let idx = r * gridCols + c
        return ZStack {
            // Burst ring — expanding outline at the exploded cell's color
            if burstOpacity[idx] > 0.0 {
                Circle()
                    .stroke(discColor(for: burstColor[idx]), lineWidth: 3)
                    .frame(width: size * 0.92, height: size * 0.92)
                    .scaleEffect(burstScale[idx])
                    .opacity(burstOpacity[idx])
                Circle()
                    .fill(discColor(for: burstColor[idx]).opacity(0.25))
                    .frame(width: size * 0.92, height: size * 0.92)
                    .scaleEffect(burstScale[idx] * 0.7)
                    .opacity(burstOpacity[idx])
            }
            // Ghost disc — the original disc shrinking/fading away
            if ghostOpacity[idx] > 0.0 && ghostValue[idx] > 0 {
                discContent(value: ghostValue[idx], size: size)
                    .scaleEffect(ghostScale[idx])
                    .opacity(ghostOpacity[idx])
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - Animation pipeline

    func performDrop(column c: Int) {
        if isAnimating || game.isGameOver || showPauseMenu { return }
        let idx = game.placePiece(column: c)
        if idx < 0 {
            playHaptic(.impact)
            return
        }
        isAnimating = true
        hasAdvancedThisDrop = false
        currentChainStep = 1
        turnMaxChain = 0
        startDropAnimation(idx: idx)
    }

    func startDropAnimation(idx: Int) {
        let row = idx / gridCols
        let stepHeight = measuredCellSize + cellGap

        // Reset cell anim values for this cell
        cellScale[idx] = 1.0
        cellScaleY[idx] = 1.0
        cellOpacity[idx] = 1.0
        // Start above the board so the piece visually falls in
        cellOffsetY[idx] = -(Double(row) + 1.5) * stepHeight

        // Pre-flight tick — small "click" feel as the piece is released
        playHaptic(HapticPattern([HapticEvent(.tick, intensity: 0.35)]))

        let distance = Double(row) + 1.5
        let response = 0.18 + 0.04 * distance

        withAnimation(.spring(response: response, dampingFraction: 0.78)) {
            cellOffsetY[idx] = 0.0
        }

        scheduleAnim(after: response * 0.9) {
            onDropLanded(idx: idx, distance: distance)
        }
    }

    func onDropLanded(idx: Int, distance: Double) {
        // Land haptic — heavier for deeper drops
        let intensity = min(1.0, 0.5 + distance * 0.06)
        playHaptic(HapticPattern([
            HapticEvent(.thud, intensity: intensity),
            HapticEvent(.tap, intensity: intensity * 0.7, delay: 0.04)
        ]))

        // Squash
        withAnimation(.easeOut(duration: 0.05)) {
            cellScaleY[idx] = 0.6
            cellScale[idx] = 1.15
        }
        scheduleAnim(after: 0.06) {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) {
                cellScaleY[idx] = 1.0
                cellScale[idx] = 1.0
            }
            scheduleAnim(after: 0.10) {
                stepExplosionChain()
            }
        }
    }

    func stepExplosionChain() {
        if let step = game.runOneExplosionStep(stepNumber: currentChainStep) {
            animateExplosionStep(step: step)
        } else {
            afterChainComplete()
        }
    }

    func animateExplosionStep(step: Drop7ExplosionStep) {
        let chainStep = step.stepNumber
        let count = step.exploded.count

        // Capture exploded values into ghost layer so the discs continue to be visible
        // even after the model has cleared them.
        var i = 0
        while i < step.exploded.count {
            let idx = step.exploded[i]
            ghostValue[idx] = step.explodedValues[i]
            ghostScale[idx] = 1.0
            ghostOpacity[idx] = 1.0
            burstColor[idx] = step.explodedValues[i]
            burstScale[idx] = 0.5
            burstOpacity[idx] = 0.0
            i += 1
        }

        // Phase 1: windup — ghost discs grow and brighten; burst opacity rises
        withAnimation(.easeOut(duration: 0.08)) {
            for ex in step.exploded {
                ghostScale[ex] = 1.32
                burstOpacity[ex] = 1.0
            }
        }

        // Pre-pop tap haptic — quick anticipation
        playHaptic(HapticPattern([HapticEvent(.tap, intensity: 0.5)]))

        // Camera shake for big chains
        if chainStep >= 3 {
            triggerShake(intensity: min(1.0, 0.4 + 0.15 * Double(chainStep)))
        }

        scheduleAnim(after: 0.08) {
            // Phase 2: pop — ghost shrinks to nothing while burst expands and fades
            playExplosionHaptic(chainStep: chainStep, count: count)

            withAnimation(.easeIn(duration: 0.16)) {
                for ex in step.exploded {
                    ghostScale[ex] = 0.0
                    ghostOpacity[ex] = 0.0
                }
            }
            withAnimation(.easeOut(duration: 0.32)) {
                for ex in step.exploded {
                    burstScale[ex] = 2.6
                    burstOpacity[ex] = 0.0
                }
            }

            // Phase 2b (concurrent): reveal pulse for cracked / revealed neighbors
            if !step.revealed.isEmpty {
                for rv in step.revealed {
                    revealScale[rv] = 1.0
                }
                withAnimation(.spring(response: 0.22, dampingFraction: 0.4)) {
                    for rv in step.revealed {
                        revealScale[rv] = 1.22
                    }
                }
                scheduleAnim(after: 0.04) {
                    playHaptic(HapticPattern([HapticEvent(.tick, intensity: 0.55)]))
                }
                scheduleAnim(after: 0.18) {
                    withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
                        for rv in step.revealed {
                            revealScale[rv] = 1.0
                        }
                    }
                }
            }

            scheduleAnim(after: 0.20) {
                // Phase 3: settle — discs above empty spots fall into place
                // Reset exploded cells' anim values (they're now empty in the model)
                for ex in step.exploded {
                    cellScale[ex] = 1.0
                    cellOpacity[ex] = 1.0
                    cellScaleY[ex] = 1.0
                    ghostValue[ex] = 0
                    ghostScale[ex] = 0.0
                    ghostOpacity[ex] = 0.0
                    burstScale[ex] = 0.0
                    burstOpacity[ex] = 0.0
                }

                applyFallSourceOffsets(fallSources: step.fallSources)

                withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                    var i = 0
                    while i < cellOffsetY.count {
                        cellOffsetY[i] = 0.0
                        i += 1
                    }
                }

                // Settle thud — a soft impact when discs land
                if hasAnyFallSources(fallSources: step.fallSources) {
                    scheduleAnim(after: 0.20) {
                        playHaptic(HapticPattern([HapticEvent(.thud, intensity: 0.45)]))
                    }
                }

                if step.screenCleared {
                    triggerScreenClearCelebration()
                }

                scheduleAnim(after: 0.32) {
                    currentChainStep += 1
                    stepExplosionChain()
                }
            }
        }
    }

    func afterChainComplete() {
        let chainCount = currentChainStep - 1
        // Track the largest chain across both the drop's chain and any push-up
        // chain that follows in the same turn. Only re-pulse the indicator when
        // the running max actually grows — a smaller push-up chain shouldn't
        // overwrite a larger drop chain.
        if chainCount > turnMaxChain {
            turnMaxChain = chainCount
            if turnMaxChain >= 2 {
                lastChainShown = turnMaxChain
                game.lastChainCount = turnMaxChain
                chainPulse = 1.0
                withAnimation(.easeOut(duration: 0.6)) {
                    chainPulse = 0.0
                }
            }
        }

        if !hasAdvancedThisDrop {
            hasAdvancedThisDrop = true
            let result = game.advanceLevel()
            if result.gameOver {
                handleGameOver()
                return
            }
            if result.didPushUp {
                animatePushUp(result: result)
                return
            }
        }
        finalizeDrop()
    }

    func animatePushUp(result: Drop7AdvanceResult) {
        let stepHeight = measuredCellSize + cellGap
        var i = 0
        while i < cellOffsetY.count {
            let src = result.fallSources[i]
            if src == fallFromBelowSentinel {
                // New bottom wrapped row — comes from below the board
                cellOffsetY[i] = stepHeight + measuredCellSize * 0.4
            } else if src >= 0 {
                cellOffsetY[i] = stepHeight
            } else {
                cellOffsetY[i] = 0.0
            }
            i += 1
        }

        playHaptic(HapticPattern([
            HapticEvent(.rise, intensity: 0.7),
            HapticEvent(.thud, intensity: 0.5, delay: 0.12),
            HapticEvent(.thud, intensity: 0.6, delay: 0.06),
        ]))

        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
            var k = 0
            while k < cellOffsetY.count {
                cellOffsetY[k] = 0.0
                k += 1
            }
        }

        scheduleAnim(after: 0.46) {
            // Push-up may trigger explosions — re-enter the chain loop
            currentChainStep = 1
            stepExplosionChain()
        }
    }

    func handleGameOver() {
        playHaptic(HapticPattern([
            HapticEvent(.thud, intensity: 1.0),
            HapticEvent(.thud, intensity: 1.0, delay: 0.08),
            HapticEvent(.fall, intensity: 1.0, delay: 0.16),
            HapticEvent(.thud, intensity: 0.9, delay: 0.18),
        ]))
        triggerShake(intensity: 1.0)
        game.saveState()
        isAnimating = false
    }

    func finalizeDrop() {
        if !game.canDropAnywhere() && !game.isGameOver {
            game.isGameOver = true
            game.saveHighScore()
            handleGameOver()
            return
        }
        if !game.isGameOver {
            game.advanceToNextPiece()
        }
        game.saveState()
        isAnimating = false
    }

    // MARK: - Helpers

    func applyFallSourceOffsets(fallSources: [Int]) {
        let stepHeight = measuredCellSize + cellGap
        var i = 0
        while i < fallSources.count {
            let src = fallSources[i]
            if src >= 0 && src != i {
                let oldRow = src / gridCols
                let newRow = i / gridCols
                cellOffsetY[i] = Double(oldRow - newRow) * stepHeight
            } else {
                cellOffsetY[i] = 0.0
            }
            i += 1
        }
    }

    func hasAnyFallSources(fallSources: [Int]) -> Bool {
        var i = 0
        while i < fallSources.count {
            if fallSources[i] >= 0 && fallSources[i] != i { return true }
            i += 1
        }
        return false
    }

    func resetAllAnimationState() {
        var i = 0
        while i < gridCols * gridRows {
            cellOffsetY[i] = 0.0
            cellScale[i] = 1.0
            cellScaleY[i] = 1.0
            cellOpacity[i] = 1.0
            ghostValue[i] = 0
            ghostScale[i] = 0.0
            ghostOpacity[i] = 0.0
            burstColor[i] = 0
            burstScale[i] = 0.0
            burstOpacity[i] = 0.0
            revealScale[i] = 1.0
            i += 1
        }
        shakeOffsetX = 0.0
        screenClearOpacity = 0.0
        screenClearScale = 0.5
        chainPulse = 0.0
        turnMaxChain = 0
    }

    func scheduleAnim(after delay: Double, block: @escaping () -> Void) {
        let t = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            block()
        }
        animTimers.append(t)
    }

    func cancelAllAnimTimers() {
        for t in animTimers {
            t.invalidate()
        }
        animTimers = []
    }

    // MARK: - Camera shake

    func triggerShake(intensity: Double) {
        // Rapid zigzag offsets that decay
        let amplitude = 8.0 * intensity
        withAnimation(.linear(duration: 0.05)) {
            shakeOffsetX = amplitude
        }
        scheduleAnim(after: 0.05) {
            withAnimation(.linear(duration: 0.05)) {
                shakeOffsetX = -amplitude * 0.8
            }
            scheduleAnim(after: 0.05) {
                withAnimation(.linear(duration: 0.05)) {
                    shakeOffsetX = amplitude * 0.5
                }
                scheduleAnim(after: 0.05) {
                    withAnimation(.linear(duration: 0.06)) {
                        shakeOffsetX = -amplitude * 0.3
                    }
                    scheduleAnim(after: 0.06) {
                        withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) {
                            shakeOffsetX = 0.0
                        }
                    }
                }
            }
        }
    }

    // MARK: - Score animation

    func startScoreAnimation() {
        if scoreAnimTimer != nil { return }
        scoreAnimTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            tickScoreAnimation()
        }
    }

    func tickScoreAnimation() {
        var changed = false
        if displayedScore != game.score {
            let diff = game.score - displayedScore
            if diff > 0 {
                let step = max(1, diff / 8)
                displayedScore = min(displayedScore + step, game.score)
            } else {
                displayedScore = game.score
            }
            changed = true
        }
        if displayedHighScore != game.highScore {
            let diff = game.highScore - displayedHighScore
            if diff > 0 {
                let step = max(1, diff / 8)
                displayedHighScore = min(displayedHighScore + step, game.highScore)
            } else {
                displayedHighScore = game.highScore
            }
            changed = true
        }
        if !changed {
            stopScoreAnimation()
        }
    }

    func stopScoreAnimation() {
        scoreAnimTimer?.invalidate()
        scoreAnimTimer = nil
    }

    // MARK: - Haptics

    func playExplosionHaptic(chainStep: Int, count: Int) {
        guard settings.vibrations else { return }
        if chainStep >= 5 {
            playMegaChainHaptic()
            return
        }
        let baseIntensity = min(1.0, 0.6 + Double(chainStep) * 0.1)
        let countBoost = min(0.3, Double(count) * 0.05)
        var events: [HapticEvent] = []
        events.append(HapticEvent(.thud, intensity: min(1.0, baseIntensity + countBoost)))
        events.append(HapticEvent(.tap, intensity: baseIntensity, delay: 0.04))
        if chainStep >= 2 {
            events.append(HapticEvent(.thud, intensity: baseIntensity * 0.85, delay: 0.05))
        }
        if chainStep >= 3 {
            events.append(HapticEvent(.tick, intensity: baseIntensity * 0.6, delay: 0.04))
            events.append(HapticEvent(.tap, intensity: baseIntensity, delay: 0.04))
        }
        HapticFeedback.play(HapticPattern(events))
    }

    func triggerScreenClearCelebration() {
        // Big haptic flourish for clearing the board
        playHaptic(HapticPattern([
            HapticEvent(.rise, intensity: 1.0),
            HapticEvent(.thud, intensity: 1.0, delay: 0.10),
            HapticEvent(.thud, intensity: 1.0, delay: 0.05),
            HapticEvent(.tap, intensity: 1.0, delay: 0.05),
            HapticEvent(.tick, intensity: 1.0, delay: 0.04),
            HapticEvent(.tap, intensity: 1.0, delay: 0.04),
            HapticEvent(.thud, intensity: 1.0, delay: 0.06),
            HapticEvent(.fall, intensity: 0.9, delay: 0.10),
        ]))
        triggerShake(intensity: 1.0)

        // Banner pop-in
        screenClearScale = 0.5
        screenClearOpacity = 0.0
        withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
            screenClearScale = 1.0
            screenClearOpacity = 1.0
        }
        scheduleAnim(after: 1.4) {
            withAnimation(.easeIn(duration: 0.4)) {
                screenClearOpacity = 0.0
                screenClearScale = 0.9
            }
        }
    }

    func playMegaChainHaptic() {
        let events: [HapticEvent] = [
            HapticEvent(.thud, intensity: 1.0),
            HapticEvent(.thud, intensity: 1.0, delay: 0.05),
            HapticEvent(.tap, intensity: 0.9, delay: 0.05),
            HapticEvent(.rise, intensity: 1.0, delay: 0.06),
            HapticEvent(.thud, intensity: 1.0, delay: 0.10),
            HapticEvent(.tick, intensity: 0.8, delay: 0.05),
            HapticEvent(.tap, intensity: 1.0, delay: 0.05),
            HapticEvent(.thud, intensity: 1.0, delay: 0.06),
            HapticEvent(.fall, intensity: 0.9, delay: 0.10),
        ]
        HapticFeedback.play(HapticPattern(events))
    }

    // MARK: - Score / Level boxes

    func scoreBox(label: String, value: Int) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(Color.white.opacity(0.7))
            Text("\(value)")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(Color.white)
                .monospaced()
        }
        .frame(minWidth: 80)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.08))
        )
    }

    func levelBox(level: Int, drops: Int, target: Int) -> some View {
        VStack(spacing: 2) {
            Text("LEVEL", bundle: .module)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(Color.white.opacity(0.7))
            Text("\(level)")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(Color.white)
                .monospaced()
            Text("\(drops)/\(target)")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.55))
                .monospaced()
        }
        .frame(minWidth: 70)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.08))
        )
    }

    // MARK: - Mini disc (for "next piece" UI)

    func miniDisc(value v: Int, size: Double) -> some View {
        ZStack {
            Circle()
                .fill(discColor(for: v))
                .frame(width: size, height: size)
            Text("\(v)")
                .font(.system(size: size * 0.55, weight: .heavy, design: .rounded))
                .foregroundStyle(discTextColor(for: v))
        }
    }

    // MARK: - HUD

    var hudView: some View {
        HStack(spacing: 8) {
            Button(action: { dismiss() }) {
                Image("cancel", bundle: .module)
                    .font(.title2)
                    .foregroundStyle(Color.white)
            }

            Spacer()

            HStack(spacing: 0) {
                Text("Drop 7", bundle: .module)
                    .font(.title)
                    .fontWeight(.black)
                    .foregroundStyle(Color.white)
                if game.difficulty != .normal {
                    Text(" (\(game.difficulty.label))")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(game.difficulty.accentColor)
                }
            }

            Spacer()

            Button(action: { showPauseMenu = true }) {
                Image("pause_circle", bundle: .module)
                    .font(.title2)
                    .foregroundStyle(Color.white)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(pageBackground)
    }

    // MARK: - Pause menu

    func pauseMenuOverlay(width: Double, height: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.85))
                .frame(width: width, height: height)

            VStack(spacing: 16) {
                Text("PAUSED", bundle: .module)
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundStyle(Color.white)

                Button(action: { showPauseMenu = false }) {
                    Text("Resume", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button(action: {
                    showPauseMenu = false
                    showDifficultyPicker = true
                    playHaptic(.snap)
                }) {
                    Text("New Game", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.30, green: 0.55, blue: 0.95))

                Button(action: {
                    showPauseMenu = false
                    showSettings = true
                }) {
                    Text("Settings", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.3, green: 0.4, blue: 0.6))

                Button(action: { dismiss() }) {
                    Text("Quit Game", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
    }

    // MARK: - Screen-clear banner

    func screenClearBanner() -> some View {
        VStack(spacing: 4) {
            Text("SCREEN CLEAR!", bundle: .module)
                .font(.system(size: 32, weight: .black, design: .rounded))
                .foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.30))
            Text("+\(drop7ScreenClearBonus)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
                .monospaced()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color(red: 1.0, green: 0.85, blue: 0.30), lineWidth: 2)
                )
        )
    }

    // MARK: - Game over overlay

    func gameOverOverlay(width: Double, height: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.78))
                .frame(width: width, height: height)

            VStack(spacing: 16) {
                Text("Game Over!", bundle: .module)
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundStyle(Color.white)

                VStack(spacing: 4) {
                    Text("Score", bundle: .module)
                        .font(.headline)
                        .foregroundStyle(Color.white.opacity(0.7))
                    Text("\(displayedScore)")
                        .font(.system(size: 44))
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                        .monospaced()
                }

                if game.score >= game.highScore && game.score > 0 {
                    Text("New High Score!", bundle: .module)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(Color(red: 0.95, green: 0.69, blue: 0.30))
                }

                Button(action: {
                    showDifficultyPicker = true
                }) {
                    Text("Try Again", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(red: 0.35, green: 0.55, blue: 0.95))
                        )
                }
                .buttonStyle(.plain)

                ShareLink(
                    item: "I scored \(game.score) in Drop 7 on Faire Games! Can you beat it?\nhttps://appfair.net",
                    subject: Text("Drop 7 Score", bundle: .module),
                    message: Text("I scored \(game.score) in Drop 7!")
                ) {
                    Label { Text("Share", bundle: .module) } icon: { Image(systemName: "square.and.arrow.up") }
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
            }
        }
    }
}

// MARK: - Preview Icon

public struct Drop7PreviewIcon: View {
    public init() { }

    public var body: some View {
        ZStack {
            pageBackground

            RoundedRectangle(cornerRadius: 4)
                .fill(boardBackground)
                .padding(8)

            VStack(spacing: 2) {
                gridRow(values: [0, 0, 0, 0, 0, 0, 0])
                gridRow(values: [0, 0, 0, 0, 0, 0, 0])
                gridRow(values: [0, 0, 0, 3, 0, 0, 0])
                gridRow(values: [0, 0, 5, 2, 6, 0, 0])
                gridRow(values: [0, 7, 1, 4, 1, 7, 0])
                gridRow(values: [-1, 5, 6, 3, 2, 4, -1])
                gridRow(values: [-1, -1, 7, -2, 5, -1, -1])
            }
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    func gridRow(values: [Int]) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<values.count, id: \.self) { i in
                miniIconCell(value: values[i])
            }
        }
    }

    func miniIconCell(value v: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(emptyCellColor)
                .frame(width: 12, height: 12)
            if v > 0 {
                Circle()
                    .fill(discColor(for: v))
                    .frame(width: 11, height: 11)
            } else if v == -1 {
                Circle()
                    .fill(wrappedColor)
                    .frame(width: 11, height: 11)
            } else if v == -2 {
                Circle()
                    .fill(crackedColor)
                    .frame(width: 11, height: 11)
            }
        }
    }
}

// MARK: - Difficulty Picker

struct Drop7DifficultyPickerView: View {
    let onSelect: (Drop7Difficulty) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Text("Choose Difficulty", bundle: .module)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                        .padding(.top, 10)

                    ForEach([Drop7Difficulty.easy, Drop7Difficulty.normal, Drop7Difficulty.hard], id: \.rawValue) { d in
                        Button(action: {
                            onSelect(d)
                            dismiss()
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(d.label)
                                        .font(.title3)
                                        .fontWeight(.bold)
                                        .foregroundStyle(Color.white)
                                    Text(d.description)
                                        .font(.caption)
                                        .foregroundStyle(Color.white.opacity(0.7))
                                }
                                Spacer()
                            }
                            .padding(16)
                            .background(d.accentColor.opacity(0.18))
                            .cornerRadius(14.0)
                            .padding(1.0)
                            .background(d.accentColor.opacity(0.5))
                            .cornerRadius(15.0)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(pageBackground.ignoresSafeArea())
            .navigationTitle(Text("New Game", bundle: .module))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) { Text("Cancel", bundle: .module) }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Settings

struct Drop7SettingsView: View {
    @Bindable var settings: Drop7Settings
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Drop 7", bundle: .module)) {
                    Toggle(isOn: $settings.vibrations) { Text("Vibrations", bundle: .module) }
                }
                Section(header: Text("Data", bundle: .module)) {
                    Button(role: .destructive, action: {
                        resetDrop7HighScore()
                    }) {
                        Text("Reset High Score", bundle: .module)
                    }
                }
            }
            .navigationTitle(Text("Settings", bundle: .module))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: { dismiss() }) { Text("Done", bundle: .module) }
                }
            }
        }
    }
}

@Observable
public class Drop7Settings {
    public var vibrations: Bool = defaults.value(forKey: "drop7Vibrations", default: true) {
        didSet { defaults.set(vibrations, forKey: "drop7Vibrations") }
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
