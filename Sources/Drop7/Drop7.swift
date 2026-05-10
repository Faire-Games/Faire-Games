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
        // Yellow needs darker text
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

    var dropsPerLevel: Int {
        switch self {
        case .easy: return 40
        case .normal: return 30
        case .hard: return 25
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

// MARK: - Game Model

@Observable
final class Drop7Model {
    // Two parallel flat arrays: state[i] in {empty, normal, cracked, wrapped}, value[i] is 1..7 or 0
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

    // Animation tracking — most recent step
    var explodedIndices: [Int] = []
    var revealedIndices: [Int] = []
    var landedIndex: Int = -1
    var maxChainValueReached: Int = 0  // largest disc value that exploded in last drop, for haptics

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
        explodedIndices = []
        revealedIndices = []
        landedIndex = -1
        maxChainValueReached = 0

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

    /// Attempt to drop currentPiece into the given column. Returns true on success.
    @discardableResult
    func drop(column col: Int) -> Bool {
        if isGameOver { return false }
        if col < 0 || col >= gridCols { return false }

        // Find lowest empty row in column (search from bottom up)
        var landingRow: Int = -1
        var r = gridRows - 1
        while r >= 0 {
            if stateGrid[cellIndex(r, col)] == stateEmpty {
                landingRow = r
                break
            }
            r -= 1
        }
        if landingRow < 0 {
            // column full — invalid drop
            return false
        }

        let idx = cellIndex(landingRow, col)
        stateGrid[idx] = stateNormal
        valueGrid[idx] = currentPiece
        landedIndex = idx
        explodedIndices = []
        revealedIndices = []
        maxChainValueReached = 0

        processChain()

        dropsThisLevel += 1
        if dropsThisLevel >= difficulty.dropsPerLevel {
            dropsThisLevel = 0
            level += 1
            pushUp()
        }

        // Check column-full game over: if top row has any cell occupied AND no column has empty space, lose.
        if !isGameOver && !hasAnyDropAvailable() {
            isGameOver = true
            saveHighScore()
        }

        if !isGameOver {
            currentPiece = nextPiece
            nextPiece = randomPieceValue()
        }
        saveHighScore()
        return true
    }

    func hasAnyDropAvailable() -> Bool {
        var c = 0
        while c < gridCols {
            if stateGrid[cellIndex(0, c)] == stateEmpty {
                return true
            }
            c += 1
        }
        return false
    }

    func processChain() {
        var step = 1
        var totalExploded: [Int] = []
        var totalRevealed: [Int] = []
        var maxValue = 0
        while true {
            let exploding = findExploding()
            if exploding.isEmpty { break }

            // Track largest exploding value (for haptic intensity)
            for ex in exploding {
                let v = valueGrid[ex]
                if v > maxValue { maxValue = v }
                totalExploded.append(ex)
            }

            // Score
            let bonus = chainBonus(forStep: step)
            score += bonus * exploding.count

            // Build set for fast neighbor lookup (avoid clearing while iterating)
            let explodingSet = Set(exploding)

            // Reveal/crack neighbors before clearing
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
                        totalRevealed.append(nidx)
                    } else if st == stateCracked {
                        stateGrid[nidx] = stateNormal
                        totalRevealed.append(nidx)
                    }
                }
            }

            // Clear exploded cells
            for ex in exploding {
                stateGrid[ex] = stateEmpty
                valueGrid[ex] = 0
            }

            // Gravity
            settle()
            step += 1
        }
        lastChainCount = step - 1
        explodedIndices = totalExploded
        revealedIndices = totalRevealed
        if maxValue > maxChainValueReached {
            maxChainValueReached = maxValue
        }
    }

    func findExploding() -> [Int] {
        var rowCount: [Int] = Array(repeating: 0, count: gridRows)
        var colCount: [Int] = Array(repeating: 0, count: gridCols)
        var r = 0
        while r < gridRows {
            var c = 0
            while c < gridCols {
                if stateGrid[cellIndex(r, c)] != stateEmpty {
                    rowCount[r] += 1
                    colCount[c] += 1
                }
                c += 1
            }
            r += 1
        }
        var result: [Int] = []
        r = 0
        while r < gridRows {
            var c = 0
            while c < gridCols {
                let idx = cellIndex(r, c)
                if stateGrid[idx] == stateNormal {
                    let v = valueGrid[idx]
                    if v == rowCount[r] || v == colCount[c] {
                        result.append(idx)
                    }
                }
                c += 1
            }
            r += 1
        }
        return result
    }

    func settle() {
        var c = 0
        while c < gridCols {
            // Collect non-empty cells from bottom to top
            var keepStates: [Int] = []
            var keepValues: [Int] = []
            var r = gridRows - 1
            while r >= 0 {
                let idx = cellIndex(r, c)
                let st = stateGrid[idx]
                if st != stateEmpty {
                    keepStates.append(st)
                    keepValues.append(valueGrid[idx])
                }
                r -= 1
            }
            // Refill column from bottom
            var ri = gridRows - 1
            var i = 0
            while i < keepStates.count {
                let idx = cellIndex(ri, c)
                stateGrid[idx] = keepStates[i]
                valueGrid[idx] = keepValues[i]
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
    }

    func pushUp() {
        // Game over if any cell in top row is non-empty (would be pushed off)
        var c = 0
        while c < gridCols {
            if stateGrid[cellIndex(0, c)] != stateEmpty {
                isGameOver = true
                saveHighScore()
                return
            }
            c += 1
        }
        // Shift all rows up by one
        var r = 0
        while r < gridRows - 1 {
            var cc = 0
            while cc < gridCols {
                let dst = cellIndex(r, cc)
                let src = cellIndex(r + 1, cc)
                stateGrid[dst] = stateGrid[src]
                valueGrid[dst] = valueGrid[src]
                cc += 1
            }
            r += 1
        }
        // Fill new bottom row with wrapped discs
        let bottom = gridRows - 1
        var c2 = 0
        while c2 < gridCols {
            let idx = cellIndex(bottom, c2)
            stateGrid[idx] = stateWrapped
            valueGrid[idx] = Int.random(in: 1...7)
            c2 += 1
        }
        // Push-up may trigger explosions (e.g., row count newly matches a disc value)
        processChain()
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
        explodedIndices = []
        revealedIndices = []
        landedIndex = -1
        maxChainValueReached = 0
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
    @State private var explodeFlash: Double = 0.0
    @State private var flashTimer: Timer? = nil
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
                    levelBox(level: game.level, drops: game.dropsThisLevel, target: game.difficulty.dropsPerLevel)
                    scoreBox(label: "BEST", value: displayedHighScore)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

                // Next-piece bar
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

                    if game.lastChainCount >= 2 {
                        Text("Chain x\(game.lastChainCount)!", bundle: .module)
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.3))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                Spacer(minLength: 0)

                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(boardBackground)
                        .frame(width: boardWidth, height: boardHeight)

                    HStack(spacing: cellGap) {
                        ForEach(0..<gridCols, id: \.self) { c in
                            Button(action: {
                                performDrop(column: c)
                            }) {
                                VStack(spacing: cellGap) {
                                    ForEach(0..<gridRows, id: \.self) { r in
                                        cellView(row: r, col: c, size: cellSize)
                                    }
                                }
                                .padding(.vertical, cellGap)
                            }
                            .buttonStyle(.plain)
                            .disabled(game.isGameOver || showPauseMenu)
                        }
                    }
                    .frame(width: boardWidth, height: boardHeight)

                    if explodeFlash > 0.0 {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(explodeFlash * 0.25))
                            .frame(width: boardWidth, height: boardHeight)
                            .allowsHitTesting(false)
                    }

                    if game.isGameOver {
                        gameOverOverlay(width: boardWidth, height: boardHeight)
                    }

                    if showPauseMenu && !game.isGameOver {
                        pauseMenuOverlay(width: boardWidth, height: boardHeight)
                    }
                }

                Spacer(minLength: 0)
            }
            .background(pageBackground.ignoresSafeArea())
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
            flashTimer?.invalidate()
            flashTimer = nil
        }
        .onChange(of: game.score) { _, _ in startScoreAnimation() }
        .onChange(of: game.highScore) { _, _ in startScoreAnimation() }
        .sheet(isPresented: $showSettings) {
            Drop7SettingsView(settings: settings)
        }
        .sheet(isPresented: $showDifficultyPicker) {
            Drop7DifficultyPickerView { d in
                Drop7Model.clearSavedState()
                game.newGame(diff: d)
                stopScoreAnimation()
                displayedScore = 0
                displayedHighScore = game.highScore
                showDifficultyPicker = false
                showPauseMenu = false
                playHaptic(.snap)
            }
        }
    }

    func performDrop(column c: Int) {
        if game.isGameOver { return }
        if showPauseMenu { return }
        let ok = game.drop(column: c)
        if !ok {
            playHaptic(.impact)
            return
        }
        playDropHaptic()
        if !game.explodedIndices.isEmpty {
            triggerFlash()
        }
        if game.isGameOver {
            playHaptic(.impact)
        }
        game.saveState()
    }

    // MARK: - Cell rendering

    func cellView(row r: Int, col c: Int, size: Double) -> some View {
        let st = game.getState(r, c)
        let v = game.getValue(r, c)
        return ZStack {
            RoundedRectangle(cornerRadius: discCornerRadius)
                .fill(emptyCellColor)
                .frame(width: size, height: size)

            if st == stateNormal {
                discContent(value: v, size: size)
            } else if st == stateCracked {
                ZStack {
                    Circle()
                        .fill(crackedColor)
                        .frame(width: size * 0.86, height: size * 0.86)
                    Text("?")
                        .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
            } else if st == stateWrapped {
                Circle()
                    .fill(wrappedColor)
                    .frame(width: size * 0.86, height: size * 0.86)
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(0.4), lineWidth: 1)
                            .frame(width: size * 0.86, height: size * 0.86)
                    )
            }
        }
    }

    func discContent(value v: Int, size: Double) -> some View {
        ZStack {
            Circle()
                .fill(discColor(for: v))
                .frame(width: size * 0.92, height: size * 0.92)
            Text("\(v)")
                .font(.system(size: size * 0.5, weight: .heavy, design: .rounded))
                .foregroundStyle(discTextColor(for: v))
        }
    }

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

    // MARK: - Flash

    func triggerFlash() {
        flashTimer?.invalidate()
        let chain = max(1, game.lastChainCount)
        let target = min(1.0, 0.3 + 0.15 * Double(chain))
        explodeFlash = target
        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            explodeFlash -= 0.06
            if explodeFlash <= 0.0 {
                explodeFlash = 0.0
                t.invalidate()
                flashTimer = nil
            }
        }
    }

    // MARK: - Haptics

    func playDropHaptic() {
        guard settings.vibrations else { return }
        let chain = game.lastChainCount
        let exploded = game.explodedIndices.count
        if exploded == 0 {
            HapticFeedback.play(.place)
            return
        }
        if chain >= 5 {
            playMegaChainHaptic()
            return
        }
        var events: [HapticEvent] = []
        var i = 0
        while i < chain {
            let intensity = min(1.0, 0.5 + Double(i) * 0.15)
            events.append(HapticEvent(.thud, intensity: intensity, delay: i == 0 ? 0.0 : 0.08))
            events.append(HapticEvent(.tap, intensity: intensity, delay: 0.04))
            i += 1
        }
        HapticFeedback.play(HapticPattern(events))
    }

    func playMegaChainHaptic() {
        let events: [HapticEvent] = [
            HapticEvent(.thud, intensity: 1.0),
            HapticEvent(.thud, intensity: 1.0, delay: 0.05),
            HapticEvent(.tap, intensity: 0.9, delay: 0.05),
            HapticEvent(.rise, intensity: 1.0, delay: 0.06),
            HapticEvent(.thud, intensity: 1.0, delay: 0.1),
            HapticEvent(.tick, intensity: 0.8, delay: 0.05),
            HapticEvent(.tap, intensity: 1.0, delay: 0.05),
            HapticEvent(.thud, intensity: 1.0, delay: 0.06),
            HapticEvent(.fall, intensity: 0.9, delay: 0.1),
        ]
        HapticFeedback.play(HapticPattern(events))
    }
}

// MARK: - Preview Icon

public struct Drop7PreviewIcon: View {
    public init() { }

    public var body: some View {
        ZStack {
            // Dark page background
            pageBackground

            RoundedRectangle(cornerRadius: 4)
                .fill(boardBackground)
                .padding(8)

            // Mini grid: scattered colored discs suggesting a Drop 7 board
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
