// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import Observation
import SkipKit
import SkipModel
import FaireGamesModel

// MARK: - Jewel Kind

enum JewelKind: Int, CaseIterable {
    case diamond = 0, ruby, emerald, sapphire, amethyst, topaz, citrine

    var lightColor: Color {
        switch self {
        case .diamond:  return Color(red: 0.88, green: 0.94, blue: 1.0)
        case .ruby:     return Color(red: 1.0,  green: 0.35, blue: 0.4)
        case .emerald:  return Color(red: 0.3,  green: 0.95, blue: 0.5)
        case .sapphire: return Color(red: 0.4,  green: 0.6,  blue: 1.0)
        case .amethyst: return Color(red: 0.78, green: 0.45, blue: 1.0)
        case .topaz:    return Color(red: 1.0,  green: 0.88, blue: 0.4)
        case .citrine:  return Color(red: 1.0,  green: 0.65, blue: 0.3)
        }
    }

    var mainColor: Color {
        switch self {
        case .diamond:  return Color(red: 0.65, green: 0.78, blue: 0.95)
        case .ruby:     return Color(red: 0.85, green: 0.1,  blue: 0.18)
        case .emerald:  return Color(red: 0.08, green: 0.72, blue: 0.28)
        case .sapphire: return Color(red: 0.12, green: 0.32, blue: 0.88)
        case .amethyst: return Color(red: 0.58, green: 0.18, blue: 0.82)
        case .topaz:    return Color(red: 0.92, green: 0.72, blue: 0.12)
        case .citrine:  return Color(red: 0.92, green: 0.48, blue: 0.08)
        }
    }

    var darkColor: Color {
        switch self {
        case .diamond:  return Color(red: 0.4,  green: 0.5,  blue: 0.7)
        case .ruby:     return Color(red: 0.55, green: 0.04, blue: 0.08)
        case .emerald:  return Color(red: 0.02, green: 0.45, blue: 0.12)
        case .sapphire: return Color(red: 0.06, green: 0.15, blue: 0.55)
        case .amethyst: return Color(red: 0.32, green: 0.06, blue: 0.5)
        case .topaz:    return Color(red: 0.65, green: 0.45, blue: 0.02)
        case .citrine:  return Color(red: 0.6,  green: 0.25, blue: 0.02)
        }
    }

    var shadowColor: Color {
        switch self {
        case .diamond:  return Color(red: 0.25, green: 0.32, blue: 0.5)
        case .ruby:     return Color(red: 0.35, green: 0.02, blue: 0.04)
        case .emerald:  return Color(red: 0.01, green: 0.28, blue: 0.06)
        case .sapphire: return Color(red: 0.03, green: 0.08, blue: 0.35)
        case .amethyst: return Color(red: 0.18, green: 0.03, blue: 0.32)
        case .topaz:    return Color(red: 0.4,  green: 0.28, blue: 0.01)
        case .citrine:  return Color(red: 0.38, green: 0.15, blue: 0.01)
        }
    }

    static func kindForRaw(_ raw: Int) -> JewelKind {
        return JewelKind(rawValue: raw) ?? .diamond
    }
}

// MARK: - Level Definitions

/// Returns target score for the given level
func levelTargetScore(_ level: Int) -> Int {
    return 500 + level * 250
}

/// Returns whether the level is timed (even levels) or untimed (odd levels)
func levelIsTimed(_ level: Int) -> Bool {
    return level % 2 == 0
}

/// Returns move limit for untimed levels
func levelMoveLimit(_ level: Int) -> Int {
    return max(25 - level / 3, 10)
}

/// Returns time limit in seconds for timed levels
func levelTimeLimit(_ level: Int) -> Int {
    return max(90 - level * 2, 35)
}

/// Returns the next playable level >= `from` matching the given preference.
func nextPlayableLevel(from start: Int, preference: String) -> Int {
    var level = start
    var safety = 0
    while safety < 200 {
        if preference == "both" { return level }
        let timed = levelIsTimed(level)
        if preference == "timed" && timed { return level }
        if preference == "untimed" && !timed { return level }
        level += 1
        safety += 1
    }
    return level
}

// MARK: - Celebration Messages

private let match3Messages = ["Nice!", "Good!", "Sweet!", "Cool!"]
private let match4Messages = ["Great!", "Awesome!", "Brilliant!", "Superb!"]
private let match5Messages = ["Amazing!", "Incredible!", "Spectacular!", "Magnificent!"]
private let cascadeMessages = ["Combo!", "Chain!", "Sweet Combo!", "Double!"]
private let bigCascadeMessages = ["Mega Combo!", "Unstoppable!", "Dazzling!", "Phenomenal!", "On Fire!"]

func celebrationMessage(largestMatch: Int, combo: Int) -> String {
    if combo >= 3 {
        return bigCascadeMessages[Int.random(in: 0..<bigCascadeMessages.count)]
    }
    if combo >= 2 {
        return cascadeMessages[Int.random(in: 0..<cascadeMessages.count)]
    }
    if largestMatch >= 5 {
        return match5Messages[Int.random(in: 0..<match5Messages.count)]
    }
    if largestMatch >= 4 {
        return match4Messages[Int.random(in: 0..<match4Messages.count)]
    }
    return match3Messages[Int.random(in: 0..<match3Messages.count)]
}

// MARK: - Game Model

@Observable final class JewelCrushModel {
    static let gridSize = 8
    static let jewelCount = 7

    var grid: [[Int]] = Array(repeating: Array(repeating: -1, count: 8), count: 8)
    var score: Int = 0
    var currentLevel: Int = 1
    var targetScore: Int = 750
    var isTimed: Bool = false
    var movesRemaining: Int = 25
    var timeRemaining: Int = 90
    var isGameOver: Bool = false
    var isLevelComplete: Bool = false
    var selectedRow: Int = -1
    var selectedCol: Int = -1
    var isAnimating: Bool = false
    var clearingCells: Set<Int> = []
    var comboCount: Int = 0
    var lastLargestMatch: Int = 0
    var lastMatchScore: Int = 0

    init() {
        loadProgress()
        startLevel(currentLevel)
    }

    // MARK: Level Setup

    func startLevel(_ level: Int) {
        currentLevel = level
        targetScore = levelTargetScore(level)
        isTimed = levelIsTimed(level)
        movesRemaining = levelMoveLimit(level)
        timeRemaining = levelTimeLimit(level)
        score = 0
        isGameOver = false
        isLevelComplete = false
        selectedRow = -1
        selectedCol = -1
        isAnimating = false
        clearingCells = []
        comboCount = 0
        generateBoard()
        saveProgress()
    }

    func generateBoard() {
        let gs = JewelCrushModel.gridSize
        let jc = JewelCrushModel.jewelCount
        // Clear the grid first so stale values don't interfere with match checks
        grid = Array(repeating: Array(repeating: -1, count: gs), count: gs)
        for r in 0..<gs {
            for c in 0..<gs {
                var kind: Int
                var attempts = 0
                repeat {
                    kind = Int.random(in: 0..<jc)
                    attempts += 1
                } while wouldMatchAt(row: r, col: c, kind: kind) && attempts < 50
                grid[r][c] = kind
            }
        }
        // Ensure valid moves exist
        if !hasValidMoves() {
            generateBoard()
        }
    }

    /// Check whether placing `kind` at (row, col) would create a run of 3.
    /// Only examines already-placed cells (left and above in fill order).
    private func wouldMatchAt(row: Int, col: Int, kind: Int) -> Bool {
        // Check two to the left
        if col >= 2 && grid[row][col - 1] == kind && grid[row][col - 2] == kind {
            return true
        }
        // Check two above
        if row >= 2 && grid[row - 1][col] == kind && grid[row - 2][col] == kind {
            return true
        }
        return false
    }

    // MARK: Swap

    func swapCells(r1: Int, c1: Int, r2: Int, c2: Int) {
        let temp = grid[r1][c1]
        grid[r1][c1] = grid[r2][c2]
        grid[r2][c2] = temp
    }

    func isAdjacent(r1: Int, c1: Int, r2: Int, c2: Int) -> Bool {
        let dr = r1 - r2
        let dc = c1 - c2
        return (dr == 0 && (dc == 1 || dc == -1)) || (dc == 0 && (dr == 1 || dr == -1))
    }

    // MARK: Match Detection

    func findAndScoreMatches() {
        clearingCells = []
        lastMatchScore = 0
        lastLargestMatch = 0
        let gs = JewelCrushModel.gridSize

        // Horizontal matches
        for r in 0..<gs {
            var c = 0
            while c < gs {
                let kind = grid[r][c]
                if kind < 0 { c += 1; continue }
                var end = c + 1
                while end < gs && grid[r][end] == kind { end += 1 }
                let matchSize = end - c
                if matchSize >= 3 {
                    for i in c..<end { clearingCells.insert(r * gs + i) }
                    if matchSize > lastLargestMatch { lastLargestMatch = matchSize }
                    if matchSize >= 5 { lastMatchScore += 350 }
                    else if matchSize >= 4 { lastMatchScore += 150 }
                    else { lastMatchScore += 60 }
                }
                c = end
            }
        }

        // Vertical matches
        for c in 0..<gs {
            var r = 0
            while r < gs {
                let kind = grid[r][c]
                if kind < 0 { r += 1; continue }
                var end = r + 1
                while end < gs && grid[end][c] == kind { end += 1 }
                let matchSize = end - r
                if matchSize >= 3 {
                    for i in r..<end { clearingCells.insert(i * gs + c) }
                    if matchSize > lastLargestMatch { lastLargestMatch = matchSize }
                    if matchSize >= 5 { lastMatchScore += 350 }
                    else if matchSize >= 4 { lastMatchScore += 150 }
                    else { lastMatchScore += 60 }
                }
                r = end
            }
        }
    }

    func hasMatchesOnBoard() -> Bool {
        let gs = JewelCrushModel.gridSize
        for r in 0..<gs {
            var c = 0
            while c < gs - 2 {
                let kind = grid[r][c]
                if kind >= 0 && grid[r][c + 1] == kind && grid[r][c + 2] == kind {
                    return true
                }
                c += 1
            }
        }
        for c in 0..<gs {
            var r = 0
            while r < gs - 2 {
                let kind = grid[r][c]
                if kind >= 0 && grid[r + 1][c] == kind && grid[r + 2][c] == kind {
                    return true
                }
                r += 1
            }
        }
        return false
    }

    // MARK: Drop & Fill

    func clearMatchedCells() {
        let gs = JewelCrushModel.gridSize
        for encoded in clearingCells {
            let r = encoded / gs
            let c = encoded % gs
            grid[r][c] = -1
        }
    }

    func dropAndFill() {
        let gs = JewelCrushModel.gridSize
        let jc = JewelCrushModel.jewelCount
        for c in 0..<gs {
            var writeRow = gs - 1
            for readRow in stride(from: gs - 1, through: 0, by: -1) {
                if grid[readRow][c] >= 0 {
                    if writeRow != readRow {
                        grid[writeRow][c] = grid[readRow][c]
                        grid[readRow][c] = -1
                    }
                    writeRow -= 1
                }
            }
            while writeRow >= 0 {
                grid[writeRow][c] = Int.random(in: 0..<jc)
                writeRow -= 1
            }
        }
    }

    // MARK: Valid Moves

    func hasValidMoves() -> Bool {
        let gs = JewelCrushModel.gridSize
        for r in 0..<gs {
            for c in 0..<gs {
                if c + 1 < gs {
                    swapCells(r1: r, c1: c, r2: r, c2: c + 1)
                    let has = hasMatchesOnBoard()
                    swapCells(r1: r, c1: c, r2: r, c2: c + 1)
                    if has { return true }
                }
                if r + 1 < gs {
                    swapCells(r1: r, c1: c, r2: r + 1, c2: c)
                    let has = hasMatchesOnBoard()
                    swapCells(r1: r, c1: c, r2: r + 1, c2: c)
                    if has { return true }
                }
            }
        }
        return false
    }

    func ensureValidMoves() {
        if !hasValidMoves() {
            generateBoard()
        }
    }

    // MARK: Scoring

    func applyMatchScore() {
        let multiplier = max(1.0, 1.0 + Double(comboCount - 1) * 0.5)
        let points = Int(Double(lastMatchScore) * multiplier)
        score += points
    }

    func checkLevelComplete() {
        if score >= targetScore {
            isLevelComplete = true
        }
    }

    func checkGameOver() {
        if isTimed {
            if timeRemaining <= 0 && score < targetScore {
                isGameOver = true
            }
        } else {
            if movesRemaining <= 0 && score < targetScore {
                isGameOver = true
            }
        }
    }

    func tickTime() {
        if isTimed && timeRemaining > 0 && !isLevelComplete && !isGameOver {
            timeRemaining -= 1
            if timeRemaining <= 0 {
                checkGameOver()
            }
        }
    }

    /// Star rating: 1 = reached target, 2 = 1.5x, 3 = 2x
    var starRating: Int {
        if score >= targetScore * 2 { return 3 }
        if score >= targetScore * 3 / 2 { return 2 }
        return 1
    }

    // MARK: Persistence

    func saveProgress() {
        UserDefaults.standard.set(currentLevel, forKey: "jewelcrush_level")
    }

    func loadProgress() {
        let saved = UserDefaults.standard.integer(forKey: "jewelcrush_level")
        currentLevel = saved > 0 ? saved : 1
    }

    static func resetProgress() {
        UserDefaults.standard.set(1, forKey: "jewelcrush_level")
    }
}

// MARK: - Container View

public struct JewelCrushContainerView: View {
    public init() { }

    public var body: some View {
        JewelCrushGameView()
            .navigationTitle("")
            #if !os(macOS)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .colorScheme(.dark)
            #endif
    }
}

// MARK: - Game View

struct JewelCrushGameView: View {
    @State var game = JewelCrushModel()
    @State var showCelebration: Bool = false
    @State var celebrationText: String = ""
    @State var gameTimer: Timer? = nil
    @State var dragRow: Int = -1
    @State var dragCol: Int = -1
    @State var dragTargetRow: Int = -1
    @State var dragTargetCol: Int = -1
    @State var dragValid: Bool = false
    @Environment(\.dismiss) var dismiss
    @Environment(AppPreferences.self) var appModel: AppPreferences

    func playHaptic(_ pattern: HapticPattern) {
        if appModel.hapticsEnabled {
            HapticFeedback.play(pattern)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let boardPadding: CGFloat = 8
            let headerHeight: CGFloat = 80
            let availableHeight = geo.size.height - headerHeight - boardPadding * 3
            let availableWidth = geo.size.width - boardPadding * 2
            let boardSize = min(availableWidth, availableHeight)
            let cs = boardSize / CGFloat(JewelCrushModel.gridSize)

            ZStack {
                // Background
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.05, blue: 0.18),
                        Color(red: 0.15, green: 0.05, blue: 0.25),
                        Color(red: 0.05, green: 0.02, blue: 0.12)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: boardPadding) {
                    headerView
                    Spacer(minLength: 0)
                    boardView(cellSize: cs, boardSize: boardSize)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, boardPadding)
                .padding(.vertical, boardPadding)

                // Celebration popup
                if showCelebration {
                    VStack {
                        Text(celebrationText)
                            .font(.title)
                            .fontWeight(.black)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.yellow, Color.orange],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .shadow(color: Color.orange.opacity(0.6), radius: 8)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.black.opacity(0.6))
                            )
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                // Level Complete overlay
                if game.isLevelComplete {
                    levelCompleteOverlay
                }

                // Game Over overlay
                if game.isGameOver && !game.isLevelComplete {
                    gameOverOverlay
                }
            }
        }
        .navigationBarBackButtonHidden()
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear { startTimerIfNeeded() }
        .onDisappear { stopTimer() }
    }

    // MARK: - Header

    var headerView: some View {
        HStack(spacing: 8) {
            Button(action: { dismiss() }) {
                Image("close", bundle: .module)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("LEVEL \(game.currentLevel)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.white.opacity(0.6))
                Text(game.isTimed ? "Timed" : "Moves")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.4))
            }

            Spacer()

            VStack(spacing: 1) {
                Text("\(game.score)")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.white)
                    .monospaced()
                Text("/ \(game.targetScore)")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.5))
            }

            Spacer()

            VStack(spacing: 1) {
                if game.isTimed {
                    let minutes = game.timeRemaining / 60
                    let seconds = game.timeRemaining % 60
                    Text("\(minutes):\(seconds < 10 ? "0" : "")\(seconds)")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(game.timeRemaining <= 10 ? Color.red : Color.white)
                        .monospaced()
                    Text("TIME")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.5))
                } else {
                    Text("\(game.movesRemaining)")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(game.movesRemaining <= 3 ? Color.red : Color.white)
                        .monospaced()
                    Text("MOVES")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.08))
        )
    }

    // MARK: - Board

    func boardView(cellSize: CGFloat, boardSize: CGFloat) -> some View {
        let gs = JewelCrushModel.gridSize
        let isDraggingGem = dragRow >= 0
        return VStack(spacing: 0) {
            ForEach(0..<gs, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<gs, id: \.self) { col in
                        let kind = game.grid[row][col]
                        let encoded = row * gs + col
                        let isClearing = game.clearingCells.contains(encoded)
                        let isSelected = game.selectedRow == row && game.selectedCol == col
                        // During drag, show swap preview: the dragged cell shows the target's gem, and vice versa
                        let isDragSource = isDraggingGem && row == dragRow && col == dragCol
                        let isDragTarget = isDraggingGem && row == dragTargetRow && col == dragTargetCol && dragTargetRow >= 0
                        let displayKind: Int = {
                            if isDragSource && dragTargetRow >= 0 {
                                return game.grid[dragTargetRow][dragTargetCol]
                            } else if isDragTarget {
                                return game.grid[dragRow][dragCol]
                            } else {
                                return kind
                            }
                        }()

                        ZStack {
                            // Cell background
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(0.03))
                                .frame(width: cellSize - 1, height: cellSize - 1)

                            if isClearing {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: cellSize * 0.7, height: cellSize * 0.7)
                                    .opacity(0.8)
                            } else if displayKind >= 0 {
                                jewelView(kind: displayKind, size: cellSize)
                                    .opacity(isDragSource ? 0.5 : 1.0)
                            }

                            // Selection ring
                            if isSelected && !game.isAnimating && !isDraggingGem {
                                RoundedRectangle(cornerRadius: cellSize * 0.15)
                                    .stroke(Color.white, lineWidth: 2.5)
                                    .frame(width: cellSize * 0.88, height: cellSize * 0.88)
                            }

                            // Drag validity indicator on target cell
                            if isDragTarget {
                                RoundedRectangle(cornerRadius: cellSize * 0.15)
                                    .stroke(dragValid ? Color.green : Color.red, lineWidth: 2.5)
                                    .frame(width: cellSize * 0.88, height: cellSize * 0.88)
                            }
                        }
                        .frame(width: cellSize, height: cellSize)
                        .onTapGesture {
                            handleCellTap(row: row, col: col)
                        }
                        .gesture(
                            DragGesture(minimumDistance: cellSize * 0.3)
                                .onChanged { value in
                                    handleDragChanged(row: row, col: col, translation: value.translation, cellSize: cellSize)
                                }
                                .onEnded { _ in
                                    handleDragEnded()
                                }
                        )
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.12, green: 0.08, blue: 0.22))
        )
    }

    // MARK: - Jewel View (Bejeweled-style shapes)

    func jewelView(kind: Int, size: CGFloat) -> some View {
        let jk = JewelKind.kindForRaw(kind)
        let s = size * 0.78
        let sp = size * 0.1
        let grad = LinearGradient(colors: [jk.lightColor, jk.mainColor, jk.darkColor], startPoint: .topLeading, endPoint: .bottomTrailing)
        let shine = LinearGradient(colors: [Color.white.opacity(0.55), Color.clear], startPoint: .top, endPoint: .center)

        return ZStack {
            switch jk {
            case .diamond:
                // Diamond: rotated square, the classic Bejeweled white/clear gem
                RoundedRectangle(cornerRadius: s * 0.1)
                    .fill(jk.shadowColor)
                    .frame(width: s * 0.65, height: s * 0.65)
                    .rotationEffect(.degrees(45))
                    .offset(y: size * 0.025)
                RoundedRectangle(cornerRadius: s * 0.1)
                    .fill(grad)
                    .frame(width: s * 0.63, height: s * 0.63)
                    .rotationEffect(.degrees(45))
                RoundedRectangle(cornerRadius: s * 0.06)
                    .fill(shine)
                    .frame(width: s * 0.35, height: s * 0.35)
                    .rotationEffect(.degrees(45))
                    .offset(y: -s * 0.08)
                Circle().fill(Color.white.opacity(0.85)).frame(width: sp, height: sp)
                    .offset(y: -s * 0.2)

            case .ruby:
                // Ruby: circle gem, the classic round red
                Circle().fill(jk.shadowColor).frame(width: s * 0.88, height: s * 0.88).offset(y: size * 0.025)
                Circle().fill(grad).frame(width: s * 0.86, height: s * 0.86)
                Circle().fill(shine).frame(width: s * 0.5, height: s * 0.38).offset(y: -s * 0.14)
                Circle().fill(Color.white.opacity(0.85)).frame(width: sp, height: sp)
                    .offset(x: -s * 0.14, y: -s * 0.18)

            case .emerald:
                // Emerald: wide rounded rectangle (emerald/cushion cut)
                RoundedRectangle(cornerRadius: s * 0.18)
                    .fill(jk.shadowColor)
                    .frame(width: s * 0.9, height: s * 0.72).offset(y: size * 0.025)
                RoundedRectangle(cornerRadius: s * 0.18)
                    .fill(grad)
                    .frame(width: s * 0.88, height: s * 0.7)
                RoundedRectangle(cornerRadius: s * 0.1)
                    .fill(shine)
                    .frame(width: s * 0.5, height: s * 0.3).offset(y: -s * 0.1)
                Circle().fill(Color.white.opacity(0.85)).frame(width: sp, height: sp)
                    .offset(x: -s * 0.18, y: -s * 0.12)

            case .sapphire:
                // Sapphire: square with slight rounding (asscher/square cut)
                RoundedRectangle(cornerRadius: s * 0.12)
                    .fill(jk.shadowColor)
                    .frame(width: s * 0.82, height: s * 0.82).offset(y: size * 0.025)
                RoundedRectangle(cornerRadius: s * 0.12)
                    .fill(grad)
                    .frame(width: s * 0.8, height: s * 0.8)
                // Inner facet lines
                RoundedRectangle(cornerRadius: s * 0.06)
                    .stroke(jk.lightColor.opacity(0.3), lineWidth: 1)
                    .frame(width: s * 0.5, height: s * 0.5)
                RoundedRectangle(cornerRadius: s * 0.08)
                    .fill(shine)
                    .frame(width: s * 0.45, height: s * 0.35).offset(y: -s * 0.1)
                Circle().fill(Color.white.opacity(0.85)).frame(width: sp, height: sp)
                    .offset(x: -s * 0.15, y: -s * 0.16)

            case .amethyst:
                // Amethyst: teardrop/pear shape (circle bottom + smaller top)
                Circle().fill(jk.shadowColor).frame(width: s * 0.68, height: s * 0.68).offset(y: s * 0.08)
                Capsule().fill(jk.shadowColor).frame(width: s * 0.32, height: s * 0.55).offset(y: -s * 0.12)
                Circle().fill(grad).frame(width: s * 0.66, height: s * 0.66).offset(y: s * 0.06)
                Capsule().fill(grad).frame(width: s * 0.3, height: s * 0.52).offset(y: -s * 0.12)
                RoundedRectangle(cornerRadius: s * 0.04)
                    .fill(jk.mainColor).frame(width: s * 0.3, height: s * 0.2).offset(y: s * 0.0)
                Circle().fill(shine).frame(width: s * 0.3, height: s * 0.25).offset(y: -s * 0.2)
                Circle().fill(Color.white.opacity(0.85)).frame(width: sp, height: sp)
                    .offset(y: -s * 0.28)

            case .topaz:
                // Topaz: hexagon-ish (tall rounded capsule, like a pillow)
                Capsule().fill(jk.shadowColor).frame(width: s * 0.6, height: s * 0.88).offset(y: size * 0.025)
                Capsule().fill(grad).frame(width: s * 0.58, height: s * 0.86)
                Capsule().fill(shine).frame(width: s * 0.3, height: s * 0.42).offset(y: -s * 0.12)
                Circle().fill(Color.white.opacity(0.85)).frame(width: sp, height: sp)
                    .offset(y: -s * 0.24)

            case .citrine:
                // Citrine: 8-pointed star (two overlapping rotated rounded rects)
                RoundedRectangle(cornerRadius: s * 0.12)
                    .fill(jk.shadowColor)
                    .frame(width: s * 0.52, height: s * 0.52).offset(y: size * 0.025)
                RoundedRectangle(cornerRadius: s * 0.12)
                    .fill(jk.shadowColor)
                    .frame(width: s * 0.52, height: s * 0.52).rotationEffect(.degrees(45)).offset(y: size * 0.025)
                RoundedRectangle(cornerRadius: s * 0.12)
                    .fill(grad)
                    .frame(width: s * 0.5, height: s * 0.5)
                RoundedRectangle(cornerRadius: s * 0.12)
                    .fill(LinearGradient(colors: [jk.lightColor, jk.mainColor, jk.darkColor], startPoint: .top, endPoint: .bottom))
                    .frame(width: s * 0.5, height: s * 0.5).rotationEffect(.degrees(45))
                Circle().fill(LinearGradient(colors: [jk.lightColor.opacity(0.6), Color.clear], startPoint: .top, endPoint: .bottom))
                    .frame(width: s * 0.34, height: s * 0.34).offset(y: -s * 0.04)
                Circle().fill(Color.white.opacity(0.85)).frame(width: sp, height: sp)
                    .offset(y: -s * 0.16)
            }
        }
    }

    // MARK: - Cell Tap Handling

    func handleCellTap(row: Int, col: Int) {
        if game.isAnimating || game.isGameOver || game.isLevelComplete { return }
        if game.grid[row][col] < 0 { return }

        if game.selectedRow < 0 {
            game.selectedRow = row
            game.selectedCol = col
            playHaptic(.pick)
        } else if game.selectedRow == row && game.selectedCol == col {
            game.selectedRow = -1
            game.selectedCol = -1
        } else if game.isAdjacent(r1: game.selectedRow, c1: game.selectedCol, r2: row, c2: col) {
            let r1 = game.selectedRow
            let c1 = game.selectedCol
            game.selectedRow = -1
            game.selectedCol = -1
            attemptSwap(r1: r1, c1: c1, r2: row, c2: col)
        } else {
            game.selectedRow = row
            game.selectedCol = col
            playHaptic(.pick)
        }
    }

    // MARK: - Drag Handling

    func handleDragChanged(row: Int, col: Int, translation: CGSize, cellSize: CGFloat) {
        if game.isAnimating || game.isGameOver || game.isLevelComplete { return }
        if game.grid[row][col] < 0 { return }

        if dragRow < 0 {
            dragRow = row
            dragCol = col
            game.selectedRow = -1
            game.selectedCol = -1
        }

        // Determine drag direction -> adjacent target cell
        let dx = translation.width
        let dy = translation.height
        var tr = row
        var tc = col
        let gs = JewelCrushModel.gridSize
        if abs(dx) > abs(dy) {
            tc = dx > 0.0 ? col + 1 : col - 1
        } else {
            tr = dy > 0.0 ? row + 1 : row - 1
        }

        // Clamp to grid
        if tr < 0 || tr >= gs || tc < 0 || tc >= gs {
            dragTargetRow = -1
            dragTargetCol = -1
            dragValid = false
            return
        }

        let oldTarget = dragTargetRow * gs + dragTargetCol
        let newTarget = tr * gs + tc
        dragTargetRow = tr
        dragTargetCol = tc

        // Check if swap would be valid
        game.swapCells(r1: row, c1: col, r2: tr, c2: tc)
        let valid = game.hasMatchesOnBoard()
        game.swapCells(r1: row, c1: col, r2: tr, c2: tc)
        dragValid = valid

        // Haptic when target changes
        if newTarget != oldTarget {
            if valid {
                playHaptic(.snap)
            } else {
                playHaptic(.warning)
            }
        }
    }

    func handleDragEnded() {
        let r1 = dragRow
        let c1 = dragCol
        let r2 = dragTargetRow
        let c2 = dragTargetCol
        let valid = dragValid

        dragRow = -1
        dragCol = -1
        dragTargetRow = -1
        dragTargetCol = -1
        dragValid = false

        if r1 < 0 || r2 < 0 { return }
        if game.isAnimating || game.isGameOver || game.isLevelComplete { return }

        if valid {
            attemptSwap(r1: r1, c1: c1, r2: r2, c2: c2)
        } else {
            playHaptic(.error)
        }
    }

    func attemptSwap(r1: Int, c1: Int, r2: Int, c2: Int) {
        game.isAnimating = true
        game.swapCells(r1: r1, c1: c1, r2: r2, c2: c2)
        game.findAndScoreMatches()

        if game.clearingCells.isEmpty {
            // No match — swap back
            game.swapCells(r1: r1, c1: c1, r2: r2, c2: c2)
            game.isAnimating = false
            playHaptic(.warning)
            return
        }

        // Valid move — consume a move
        if !game.isTimed {
            game.movesRemaining -= 1
        }

        game.comboCount = 0
        processCascade()
    }

    func processCascade() {
        game.findAndScoreMatches()

        if game.clearingCells.isEmpty {
            // No more matches — cascade done
            game.isAnimating = false
            game.ensureValidMoves()
            game.checkLevelComplete()
            if !game.isLevelComplete {
                game.checkGameOver()
            }
            return
        }

        game.comboCount += 1
        game.applyMatchScore()

        // Show celebration
        let msg = celebrationMessage(largestMatch: game.lastLargestMatch, combo: game.comboCount)
        celebrationText = msg
        showCelebration = true

        // Play haptic based on match quality
        if game.comboCount >= 3 {
            playHaptic(.bigCelebrate)
        } else if game.lastLargestMatch >= 4 || game.comboCount >= 2 {
            playHaptic(.celebrate)
        } else {
            playHaptic(.snap)
        }

        // After delay, clear and drop
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            showCelebration = false
            game.clearMatchedCells()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                game.dropAndFill()
                game.clearingCells = []

                // Check for more cascading matches
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    processCascade()
                }
            }
        }
    }

    // MARK: - Timer

    func startTimerIfNeeded() {
        if game.isTimed && !game.isLevelComplete && !game.isGameOver {
            gameTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                game.tickTime()
            }
        }
    }

    func stopTimer() {
        gameTimer?.invalidate()
        gameTimer = nil
    }

    // MARK: - Level Complete Overlay

    var levelCompleteOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                // Stars
                HStack(spacing: 4) {
                    ForEach(1..<4, id: \.self) { star in
                        Text(star <= game.starRating ? "\u{2B50}" : "\u{2606}")
                            .font(.system(size: 36))
                    }
                }

                Text("Level Complete!")
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.yellow, Color.orange],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                VStack(spacing: 4) {
                    Text("Score: \(game.score)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                    Text("Target: \(game.targetScore)")
                        .font(.callout)
                        .foregroundStyle(Color.white.opacity(0.6))
                }

                Button(action: {
                    stopTimer()
                    let pref = UserDefaults.standard.string(forKey: "levelPreference") ?? "both"
                    let next = nextPlayableLevel(from: game.currentLevel + 1, preference: pref)
                    game.startLevel(next)
                    startTimerIfNeeded()
                }) {
                    Text("Next Level")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                        .frame(width: 180, height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(
                                    LinearGradient(
                                        colors: [Color(red: 0.3, green: 0.7, blue: 0.3), Color(red: 0.15, green: 0.5, blue: 0.15)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                }

                Button(action: {
                    stopTimer()
                    dismiss()
                }) {
                    Text("Quit")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(red: 0.12, green: 0.08, blue: 0.22))
            )
        }
    }

    // MARK: - Game Over Overlay

    var gameOverOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text(game.isTimed ? "Time's Up!" : "Out of Moves!")
                    .font(.title)
                    .fontWeight(.heavy)
                    .foregroundStyle(Color.white)

                VStack(spacing: 4) {
                    Text("Score: \(game.score)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                    Text("Target: \(game.targetScore)")
                        .font(.callout)
                        .foregroundStyle(Color.red.opacity(0.8))
                }

                Button(action: {
                    stopTimer()
                    game.startLevel(game.currentLevel)
                    startTimerIfNeeded()
                }) {
                    Text("Retry")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                        .frame(width: 160, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(red: 0.2, green: 0.5, blue: 0.9))
                        )
                }

                Button(action: {
                    stopTimer()
                    dismiss()
                }) {
                    Text("Quit Game")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                        .frame(width: 160, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(red: 0.8, green: 0.2, blue: 0.2))
                        )
                }
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(red: 0.12, green: 0.08, blue: 0.22))
            )
        }
    }
}

// MARK: - Public Reset

/// Resets JewelCrush progress back to level 1.
public func resetJewelCrushProgress() {
    JewelCrushModel.resetProgress()
}

// MARK: - Preview Icon

/// Returns the jewel kind for a preview icon cell, or -1 if empty.
private func jewelPreviewKind(row: Int, col: Int) -> Int {
    // Colorful diagonal stripe pattern
    let gs = 6
    if row < 0 || row >= gs || col < 0 || col >= gs { return -1 }
    return (row + col) % JewelCrushModel.jewelCount
}

/// Renders a small gem shape for the preview icon matching the Bejeweled-style shapes.
private func previewGem(kind: Int, gs: CGFloat) -> some View {
    let jk = JewelKind.kindForRaw(kind)
    let grad = LinearGradient(colors: [jk.lightColor, jk.mainColor, jk.darkColor], startPoint: .topLeading, endPoint: .bottomTrailing)

    return ZStack {
        switch jk {
        case .diamond:
            // Diamond shape
            RoundedRectangle(cornerRadius: gs * 0.06)
                .fill(grad)
                .frame(width: gs * 0.48, height: gs * 0.48)
                .rotationEffect(.degrees(45))
        case .ruby:
            // Round gem
            Circle().fill(grad).frame(width: gs * 0.66, height: gs * 0.66)
        case .emerald:
            // Wide cushion cut
            RoundedRectangle(cornerRadius: gs * 0.12)
                .fill(grad)
                .frame(width: gs * 0.68, height: gs * 0.52)
        case .sapphire:
            // Square cut
            RoundedRectangle(cornerRadius: gs * 0.08)
                .fill(grad)
                .frame(width: gs * 0.62, height: gs * 0.62)
        case .amethyst:
            // Teardrop
            Circle().fill(grad).frame(width: gs * 0.48, height: gs * 0.48).offset(y: gs * 0.06)
            Capsule().fill(grad).frame(width: gs * 0.22, height: gs * 0.38).offset(y: -gs * 0.1)
        case .topaz:
            // Tall capsule
            Capsule().fill(grad).frame(width: gs * 0.42, height: gs * 0.66)
        case .citrine:
            // Star shape
            RoundedRectangle(cornerRadius: gs * 0.08)
                .fill(grad)
                .frame(width: gs * 0.4, height: gs * 0.4)
            RoundedRectangle(cornerRadius: gs * 0.08)
                .fill(grad)
                .frame(width: gs * 0.4, height: gs * 0.4)
                .rotationEffect(.degrees(45))
        }
    }
}

/// A preview icon for the JewelCrush game showing colorful jewels.
public struct JewelCrushPreviewIcon: View {
    public init() { }

    public var body: some View {
        GeometryReader { geo in
            let gs = 6
            let padding: CGFloat = 4
            let available = min(geo.size.width, geo.size.height) - padding * 2
            let cs = available / CGFloat(gs)

            VStack(spacing: 0) {
                ForEach(0..<gs, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<gs, id: \.self) { col in
                            let kind = jewelPreviewKind(row: row, col: col)
                            ZStack {
                                if kind >= 0 {
                                    previewGem(kind: kind, gs: cs)
                                }
                            }
                            .frame(width: cs, height: cs)
                        }
                    }
                }
            }
            .padding(padding)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.1, green: 0.06, blue: 0.2))
        )
    }
}
