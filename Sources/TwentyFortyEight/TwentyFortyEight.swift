// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import Observation
import SkipKit
import FaireGamesModel

public struct TwentyFortyEightContainerView: View {
    @State private var settings = TwentyFortyEightSettings()
    @State private var showInstructions: Bool = false
    private let instructionsConfig = GameInstructionsConfig(
        key: "TwentyFortyEight.instructions",
        bundle: .module,
        firstLaunchKey: "instructionsShown_TwentyFortyEight",
        title: "2048"
    )

    public init() { }

    public var body: some View {
        TwentyFortyEightGameView(showInstructions: $showInstructions)
            .navigationTitle("")
            #if !os(macOS)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .colorScheme(settings.theme.isDark ? .dark : .light)
            #endif
            .environment(settings)
            .sheet(isPresented: $showInstructions) {
                GameInstructionsView(config: instructionsConfig)
            }
            .onAppear {
                if !instructionsConfig.hasShownToUser() {
                    instructionsConfig.markShownToUser()
                    showInstructions = true
                }
            }
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

// MARK: - Difficulty

enum TwentyFortyEightDifficulty: Int, CaseIterable {
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
        case .easy: return "Only 2s spawn. 3 undos per game."
        case .normal: return "Classic rules. 90% twos, 10% fours."
        case .hard: return "20% fours. Two tiles spawn per move."
        }
    }

    var accentColor: Color {
        switch self {
        case .easy: return Color(red: 0.35, green: 0.75, blue: 0.45)
        case .normal: return Color(red: 0.30, green: 0.60, blue: 0.95)
        case .hard: return Color(red: 0.90, green: 0.35, blue: 0.30)
        }
    }

    /// Probability of spawning a 4 instead of a 2
    var fourSpawnChance: Double {
        switch self {
        case .easy: return 0.0
        case .normal: return 0.1
        case .hard: return 0.2
        }
    }

    /// How many tiles to spawn per move
    var tilesPerSpawn: Int {
        switch self {
        case .easy: return 1
        case .normal: return 1
        case .hard: return 2
        }
    }

    /// Whether undo is available
    var undoAllowed: Bool {
        switch self {
        case .easy: return true
        case .normal: return false
        case .hard: return false
        }
    }
}

// MARK: - Direction

enum Direction {
    case up, down, left, right
}

// MARK: - Move Preview

/// One tile's movement under a hypothetical move. Used to drive the live
/// drag-preview animation in the view layer.
///
/// - `startCell`: the grid index where the tile currently lives.
/// - `endCell`: the grid index where it will visually end up.
/// - `isAbsorbedSource`: true if this tile is the *second* tile in a merge
///   pair — i.e., it disappears into the destination tile and the destination
///   ends up holding the doubled value. The corresponding *destination* tile
///   shares the same `endCell` but has `isAbsorbedSource == false`.
/// - `value`: the tile's pre-move value, used by the view for highlighting.
struct TwentyFortyEightTileMovement {
    let startCell: Int
    let endCell: Int
    let isAbsorbedSource: Bool
    let value: Int
}

struct TwentyFortyEightMovePreview {
    let direction: Direction
    let movements: [TwentyFortyEightTileMovement]

    /// True if any tile actually changes position under this move. If false
    /// the gesture should be ignored (the user is dragging into a wall).
    var anyMovement: Bool {
        var i = 0
        while i < movements.count {
            if movements[i].startCell != movements[i].endCell { return true }
            i += 1
        }
        return false
    }
}

// MARK: - Saved State

struct TwentyFortyEightSavedState: Codable {
    var grid: [Int]
    var score: Int
    var isGameOver: Bool
    var hasWon: Bool
    var continueAfterWin: Bool
    var difficultyRaw: Int
    var undoGrid: [Int]
    var undoScore: Int
    var hasUndo: Bool
    var undosRemaining: Int
}

// MARK: - Game Model

/// Internal record used by `Drop7Model.simulateLine` to describe a tile's
/// movement within a single line (row or column) under a hypothetical move.
private struct LineMovement {
    let startInLine: Int
    let endInLine: Int
    let isAbsorbedSource: Bool
    let value: Int
}

@Observable
final class TwentyFortyEightModel {
    // Grid stored as flat array [row * gridSize + col], row-major
    var grid: [Int] = Array(repeating: 0, count: gridSize * gridSize)

    var score: Int = 0
    var highScore: Int = UserDefaults.standard.integer(forKey: "twentyfortyeight_highscore")
    var isGameOver: Bool = false
    var hasWon: Bool = false
    var continueAfterWin: Bool = false
    var difficulty: TwentyFortyEightDifficulty = .normal

    // Undo support
    var undoGrid: [Int] = Array(repeating: 0, count: gridSize * gridSize)
    var undoScore: Int = 0
    var hasUndo: Bool = false
    var undosRemaining: Int = 3

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

    func newGame(diff: TwentyFortyEightDifficulty? = nil) {
        if let diff = diff {
            difficulty = diff
        }
        grid = Array(repeating: 0, count: gridSize * gridSize)
        score = 0
        isGameOver = false
        hasWon = false
        continueAfterWin = false
        mergedIndices = []
        spawnedIndex = -1
        hasUndo = false
        undosRemaining = 3
        undoGrid = Array(repeating: 0, count: gridSize * gridSize)
        undoScore = 0
        spawnTile()
        spawnTile()
    }

    /// Save current state for undo before a move
    func saveUndoState() {
        if difficulty.undoAllowed && undosRemaining > 0 {
            undoGrid = grid
            undoScore = score
            hasUndo = true
        }
    }

    /// Restore the last saved undo state
    func undo() {
        guard hasUndo && difficulty.undoAllowed && undosRemaining > 0 else { return }
        grid = undoGrid
        score = undoScore
        isGameOver = false
        hasUndo = false
        undosRemaining -= 1
        mergedIndices = []
        spawnedIndex = -1
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
        grid[idx] = Double.random(in: 0.0...1.0) < difficulty.fourSpawnChance ? 4 : 2
        spawnedIndex = idx
    }

    /// Spawn the appropriate number of tiles for the current difficulty
    func spawnTilesForMove() {
        for _ in 0..<difficulty.tilesPerSpawn {
            spawnTile()
        }
    }

    // MARK: - Move preview (non-mutating)

    /// Compute what would happen if the given move were committed, without
    /// touching the grid. The view layer uses this to drive a live drag
    /// preview: every tile that would shift gets `startCell != endCell`, and
    /// the absorbed-source tile of a merge pair is flagged so the view can
    /// highlight it. Safe to call repeatedly.
    func previewMove(_ direction: Direction) -> TwentyFortyEightMovePreview {
        var movements: [TwentyFortyEightTileMovement] = []
        switch direction {
        case .left:
            var r = 0
            while r < gridSize {
                let row = extractRow(r)
                let lineMovs = simulateLine(row)
                for m in lineMovs {
                    movements.append(TwentyFortyEightTileMovement(
                        startCell: r * gridSize + m.startInLine,
                        endCell: r * gridSize + m.endInLine,
                        isAbsorbedSource: m.isAbsorbedSource,
                        value: m.value
                    ))
                }
                r += 1
            }
        case .right:
            var r = 0
            while r < gridSize {
                let row = extractRow(r)
                let reversedLine = Array(row.reversed())
                let lineMovs = simulateLine(reversedLine)
                for m in lineMovs {
                    let startCol = (gridSize - 1) - m.startInLine
                    let endCol = (gridSize - 1) - m.endInLine
                    movements.append(TwentyFortyEightTileMovement(
                        startCell: r * gridSize + startCol,
                        endCell: r * gridSize + endCol,
                        isAbsorbedSource: m.isAbsorbedSource,
                        value: m.value
                    ))
                }
                r += 1
            }
        case .up:
            var c = 0
            while c < gridSize {
                let col = extractCol(c)
                let lineMovs = simulateLine(col)
                for m in lineMovs {
                    movements.append(TwentyFortyEightTileMovement(
                        startCell: m.startInLine * gridSize + c,
                        endCell: m.endInLine * gridSize + c,
                        isAbsorbedSource: m.isAbsorbedSource,
                        value: m.value
                    ))
                }
                c += 1
            }
        case .down:
            var c = 0
            while c < gridSize {
                let col = extractCol(c)
                let reversedLine = Array(col.reversed())
                let lineMovs = simulateLine(reversedLine)
                for m in lineMovs {
                    let startRow = (gridSize - 1) - m.startInLine
                    let endRow = (gridSize - 1) - m.endInLine
                    movements.append(TwentyFortyEightTileMovement(
                        startCell: startRow * gridSize + c,
                        endCell: endRow * gridSize + c,
                        isAbsorbedSource: m.isAbsorbedSource,
                        value: m.value
                    ))
                }
                c += 1
            }
        }
        return TwentyFortyEightMovePreview(direction: direction, movements: movements)
    }

    /// Per-line simulation shared by `previewMove`. Given a line oriented so
    /// the merge target is index 0, returns one record per non-zero tile with
    /// its post-move position (still in the same line orientation) and merge
    /// role. Mirrors the structure of `mergeLine` but never mutates state.
    private func simulateLine(_ line: [Int]) -> [LineMovement] {
        var nonZeroIndices: [Int] = []
        var nonZeroValues: [Int] = []
        var i = 0
        while i < line.count {
            if line[i] != 0 {
                nonZeroIndices.append(i)
                nonZeroValues.append(line[i])
            }
            i += 1
        }

        var result: [LineMovement] = []
        var resultPos = 0
        var k = 0
        while k < nonZeroValues.count {
            let curIdx = nonZeroIndices[k]
            let curVal = nonZeroValues[k]
            if k + 1 < nonZeroValues.count && nonZeroValues[k + 1] == curVal {
                let nextIdx = nonZeroIndices[k + 1]
                // First of the pair stays at resultPos as the merge destination.
                result.append(LineMovement(startInLine: curIdx, endInLine: resultPos, isAbsorbedSource: false, value: curVal))
                // Second of the pair is absorbed into the same resultPos.
                result.append(LineMovement(startInLine: nextIdx, endInLine: resultPos, isAbsorbedSource: true, value: curVal))
                k += 2
            } else {
                result.append(LineMovement(startInLine: curIdx, endInLine: resultPos, isAbsorbedSource: false, value: curVal))
                k += 1
            }
            resultPos += 1
        }
        return result
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
            continueAfterWin: continueAfterWin,
            difficultyRaw: difficulty.rawValue,
            undoGrid: undoGrid,
            undoScore: undoScore,
            hasUndo: hasUndo,
            undosRemaining: undosRemaining
        )
    }

    func restoreState(_ state: TwentyFortyEightSavedState) {
        grid = state.grid
        score = state.score
        isGameOver = state.isGameOver
        hasWon = state.hasWon
        continueAfterWin = state.continueAfterWin
        difficulty = TwentyFortyEightDifficulty(rawValue: state.difficultyRaw) ?? .normal
        undoGrid = state.undoGrid
        undoScore = state.undoScore
        hasUndo = state.hasUndo
        undosRemaining = state.undosRemaining
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
    @Binding var showInstructions: Bool
    @State private var game = TwentyFortyEightModel()
    @State private var showSettings = false
    @State private var showPauseMenu = false
    @State private var showDifficultyPicker = false
    @State private var hasInitialized = false
    @State private var tileScales: [Double] = Array(repeating: 1.0, count: gridSize * gridSize)
    @State private var animTimer: Timer? = nil
    @State private var displayedScore: Int = 0
    @State private var displayedHighScore: Int = 0
    @State private var scoreAnimTimer: Timer? = nil

    // MARK: - Drag-preview state

    /// Locked direction for the current drag, or nil if no drag in progress.
    @State private var dragDirection: Direction? = nil
    /// The preview corresponding to `dragDirection`.
    @State private var dragPreview: TwentyFortyEightMovePreview? = nil
    /// Per-cell visual offset applied while dragging (in points).
    @State private var tileOffsetX: [Double] = Array(repeating: 0.0, count: gridSize * gridSize)
    @State private var tileOffsetY: [Double] = Array(repeating: 0.0, count: gridSize * gridSize)
    /// Per-cell maximum offset magnitude along the locked drag axis (positive).
    /// Used to clamp the live drag offset to the tile's intended destination.
    @State private var tileMaxAxisOffset: [Double] = Array(repeating: 0.0, count: gridSize * gridSize)
    /// 0..1 glow intensity for the *absorbed source* of a merge — the tile
    /// that disappears into another. Rendered as a bright gold border.
    @State private var tileMergeGlow: [Double] = Array(repeating: 0.0, count: gridSize * gridSize)
    /// 0..1 glow intensity for the *destination* tile of a merge — the tile
    /// that will hold the doubled value. Rendered as a softer accent border.
    @State private var tileDestGlow: [Double] = Array(repeating: 0.0, count: gridSize * gridSize)
    /// Latest measured cell size (in points). Captured from the GeometryReader
    /// so gesture handlers can compute pixel offsets without rebuilding the view.
    @State private var measuredCellSize: Double = 0.0
    /// Step size between cell origins (cellSize + gridSpacing). The distance a
    /// tile travels for a one-cell shift.
    @State private var measuredStepSize: Double = 0.0
    /// True when the current drag-attempt direction has no possible movements
    /// (dragging into a wall). Suppresses the "lock failed" haptic repeat.
    @State private var dragRejected: Bool = false

    @Environment(\.dismiss) var dismiss
    @Environment(TwentyFortyEightSettings.self) var settings: TwentyFortyEightSettings

    var theme: TwentyFortyEightTheme { return settings.theme }

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

                // Score row
                HStack(spacing: 12) {
                    scoreBox(label: "SCORE", value: displayedScore)
                    scoreBox(label: "BEST", value: displayedHighScore)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

                Spacer()

                // Board
                ZStack {
                    // Board background
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.boardBackground)
                        .frame(width: boardSize, height: boardSize)

                    // Empty cell placeholders
                    VStack(spacing: gridSpacing) {
                        ForEach(0..<gridSize, id: \.self) { r in
                            HStack(spacing: gridSpacing) {
                                ForEach(0..<gridSize, id: \.self) { c in
                                    RoundedRectangle(cornerRadius: tileCornerRadius)
                                        .fill(theme.emptyCellBackground.opacity(theme.emptyCellOpacity))
                                        .frame(width: cellSize, height: cellSize)
                                }
                            }
                        }
                    }

                    // Tile values — single ZStack with absolute positioning so
                    // every tile is a *sibling* of every other tile. zIndex
                    // applied to a sibling actually controls global stacking
                    // order, which a VStack-of-HStacks layout cannot do (a
                    // tile in row 0's HStack can never render above row 1's
                    // HStack, no matter what zIndex it carries).
                    //
                    // Offsets are expressed relative to the *center* of the
                    // ZStack (its default alignment): a tile's natural layout
                    // position is the ZStack center, and the per-cell offset
                    // shifts it out from there. Center-relative math avoids
                    // depending on `alignment: .topLeading`, which Skip can
                    // fall back to `.center` for and would otherwise drop the
                    // whole grid into the bottom-right quadrant of the board.
                    ZStack {
                        ForEach(0..<(gridSize * gridSize), id: \.self) { index in
                            let r = index / gridSize
                            let c = index % gridSize
                            let stepSize = cellSize + gridSpacing
                            let centerOffset = Double(gridSize - 1) / 2.0
                            let cellOffsetX = (Double(c) - centerOffset) * stepSize
                            let cellOffsetY = (Double(r) - centerOffset) * stepSize
                            tileView(value: game.tile(r, c), cellSize: cellSize)
                                .scaleEffect(game.tile(r, c) > 0 ? tileScales[index] : 1.0)
                                .overlay(mergeHighlightOverlay(idx: index, cellSize: cellSize))
                                .offset(x: cellOffsetX + tileOffsetX[index], y: cellOffsetY + tileOffsetY[index])
                                .zIndex(dragZIndex(for: index))
                        }
                    }
                    .frame(width: boardSize, height: boardSize)

                    // Win overlay
                    if game.hasWon {
                        winOverlay(boardSize: boardSize)
                    }

                    // Game over overlay
                    if game.isGameOver {
                        gameOverOverlay(boardSize: boardSize)
                    }

                    // Pause menu overlay
                    if showPauseMenu && !game.isGameOver && !game.hasWon {
                        pauseMenuOverlay(boardSize: boardSize)
                    }
                }

                Spacer()
                Spacer()
            }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        handleDragChanged(translationWidth: Double(value.translation.width), translationHeight: Double(value.translation.height))
                    }
                    .onEnded { value in
                        handleDragEnded(translationWidth: Double(value.translation.width), translationHeight: Double(value.translation.height))
                    }
            )
            .background(theme.background.ignoresSafeArea())
            .onAppear {
                measuredCellSize = cellSize
                measuredStepSize = cellSize + gridSpacing
            }
            .onChange(of: cellSize) { _, newValue in
                measuredCellSize = newValue
                measuredStepSize = newValue + gridSpacing
            }
        }
        .navigationBarBackButtonHidden()
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear {
            if !hasInitialized {
                hasInitialized = true
                if let state = TwentyFortyEightModel.loadSavedState() {
                    game.restoreState(state)
                } else {
                    showDifficultyPicker = true
                }
            }
            displayedScore = game.score
            displayedHighScore = game.highScore
            resetScales()
        }
        .onDisappear {
            animTimer?.invalidate()
            animTimer = nil
            stopScoreAnimation()
        }
        .onChange(of: game.score) { _, newScore in
            if newScore == 0 {
                displayedScore = 0
            } else {
                startScoreAnimation()
            }
        }
        .onChange(of: game.highScore) { _, newHighScore in
            if newHighScore == 0 {
                displayedHighScore = 0
            } else {
                startScoreAnimation()
            }
        }
        .sheet(isPresented: $showSettings) {
            TwentyFortyEightSettingsView(settings: settings)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showDifficultyPicker) {
            TwentyFortyEightDifficultyPickerView(theme: theme) { newDifficulty in
                TwentyFortyEightModel.clearSavedState()
                game.newGame(diff: newDifficulty)
                resetScales()
                stopScoreAnimation()
                displayedScore = 0
                displayedHighScore = game.highScore
                showDifficultyPicker = false
                showPauseMenu = false
                playHaptic(.snap)
            }
        }
    }

    // MARK: - Pause Menu

    func pauseMenuOverlay(boardSize: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.boardBackground.opacity(0.92))
                .frame(width: boardSize, height: boardSize)

            VStack(spacing: 16) {
                Text("PAUSED", bundle: .module)
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundStyle(Color.white)

                Button(action: {
                    showPauseMenu = false
                }) {
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

                Button(action: {
                    showPauseMenu = false
                    showInstructions = true
                }) {
                    Text("Instructions", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.4, green: 0.4, blue: 0.7))

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

    // MARK: - Score Animation

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
            scoreAnimTimer?.invalidate()
            scoreAnimTimer = nil
        }
    }

    func stopScoreAnimation() {
        scoreAnimTimer?.invalidate()
        scoreAnimTimer = nil
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

    // MARK: - Drag preview

    /// Visual lock threshold: how many points of motion are required before
    /// we lock a drag direction. The DragGesture itself uses
    /// `minimumDistance: 8`, and we add a small extra buffer so accidental
    /// taps that just barely register as drags don't lock a direction.
    private var dragLockThreshold: Double { return 10.0 }

    func handleDragChanged(translationWidth: Double, translationHeight: Double) {
        if game.isGameOver || game.hasWon || showPauseMenu || showDifficultyPicker { return }

        let dx = translationWidth
        let dy = translationHeight

        if dragDirection == nil {
            let absX = dx < 0.0 ? -dx : dx
            let absY = dy < 0.0 ? -dy : dy
            let largest = max(absX, absY)
            if largest < dragLockThreshold { return }

            let candidate: Direction
            if absX > absY {
                candidate = dx > 0.0 ? .right : .left
            } else {
                candidate = dy > 0.0 ? .down : .up
            }

            let preview = game.previewMove(candidate)
            if !preview.anyMovement {
                if !dragRejected {
                    dragRejected = true
                    playHaptic(HapticPattern([HapticEvent(.tick, intensity: 0.25)]))
                }
                return
            }

            lockDirection(candidate, preview: preview)
        }

        guard let dir = dragDirection else { return }
        let axisDrag: Double
        switch dir {
        case .right: axisDrag = dx > 0.0 ? dx : 0.0
        case .left:  axisDrag = dx < 0.0 ? -dx : 0.0
        case .down:  axisDrag = dy > 0.0 ? dy : 0.0
        case .up:    axisDrag = dy < 0.0 ? -dy : 0.0
        }
        applyAxisDrag(axisDrag, direction: dir)
    }

    func handleDragEnded(translationWidth: Double, translationHeight: Double) {
        defer { dragRejected = false }

        guard let dir = dragDirection else { return }

        let dx = translationWidth
        let dy = translationHeight
        let axisDrag: Double
        switch dir {
        case .right: axisDrag = dx > 0.0 ? dx : 0.0
        case .left:  axisDrag = dx < 0.0 ? -dx : 0.0
        case .down:  axisDrag = dy > 0.0 ? dy : 0.0
        case .up:    axisDrag = dy < 0.0 ? -dy : 0.0
        }

        // Commit if the user dragged at least halfway across one cell. Past
        // that point each tile is visually closer to its destination than its
        // origin (capped at destination for tiles that have already arrived).
        let commitThreshold = max(measuredStepSize * 0.5, 24.0)
        if axisDrag >= commitThreshold {
            commitMove(direction: dir)
        } else {
            cancelDrag()
        }
    }

    /// Lock the drag direction and prep per-cell animation targets from
    /// `preview`. Called once at the start of a drag.
    func lockDirection(_ direction: Direction, preview: TwentyFortyEightMovePreview) {
        dragDirection = direction
        dragPreview = preview

        var i = 0
        while i < gridSize * gridSize {
            tileOffsetX[i] = 0.0
            tileOffsetY[i] = 0.0
            tileMaxAxisOffset[i] = 0.0
            tileMergeGlow[i] = 0.0
            tileDestGlow[i] = 0.0
            i += 1
        }

        for m in preview.movements {
            let deltaCells: Int
            switch direction {
            case .left, .right:
                let startCol = m.startCell % gridSize
                let endCol = m.endCell % gridSize
                let d = endCol - startCol
                deltaCells = d < 0 ? -d : d
            case .up, .down:
                let startRow = m.startCell / gridSize
                let endRow = m.endCell / gridSize
                let d = endRow - startRow
                deltaCells = d < 0 ? -d : d
            }
            if deltaCells > 0 {
                tileMaxAxisOffset[m.startCell] = Double(deltaCells) * measuredStepSize
            }
        }

        // Build the set of endCells that are merge targets (so we can identify
        // the destination tile of each merge — the one we want the soft accent
        // glow on). Then the destination's glow is attached to its *startCell*
        // so the highlight follows the tile while it slides into the merge,
        // not the empty cell it will end up at.
        var mergeDestEndCells: Set<Int> = []
        for m in preview.movements {
            if m.isAbsorbedSource {
                mergeDestEndCells.insert(m.endCell)
            }
        }

        withAnimation(.easeOut(duration: 0.16)) {
            for m in preview.movements {
                if m.isAbsorbedSource {
                    tileMergeGlow[m.startCell] = 1.0
                } else if mergeDestEndCells.contains(m.endCell) {
                    tileDestGlow[m.startCell] = 1.0
                }
            }
        }

        playHaptic(HapticPattern([HapticEvent(.tick, intensity: 0.4)]))
    }

    /// Update per-cell offsets from the current axis drag magnitude.
    func applyAxisDrag(_ axisDrag: Double, direction: Direction) {
        var i = 0
        while i < gridSize * gridSize {
            let maxOff = tileMaxAxisOffset[i]
            if maxOff <= 0.0 {
                tileOffsetX[i] = 0.0
                tileOffsetY[i] = 0.0
                i += 1
                continue
            }
            let clamped = axisDrag < maxOff ? axisDrag : maxOff
            switch direction {
            case .right:
                tileOffsetX[i] = clamped
                tileOffsetY[i] = 0.0
            case .left:
                tileOffsetX[i] = -clamped
                tileOffsetY[i] = 0.0
            case .down:
                tileOffsetX[i] = 0.0
                tileOffsetY[i] = clamped
            case .up:
                tileOffsetX[i] = 0.0
                tileOffsetY[i] = -clamped
            }
            i += 1
        }
    }

    /// User released past the commit threshold — finish the move.
    func commitMove(direction: Direction) {
        // Snap any laggy tile offsets all the way to their destination so the
        // model mutation lines up with the rendered position.
        var i = 0
        while i < gridSize * gridSize {
            let maxOff = tileMaxAxisOffset[i]
            if maxOff > 0.0 {
                switch direction {
                case .right: tileOffsetX[i] = maxOff
                case .left:  tileOffsetX[i] = -maxOff
                case .down:  tileOffsetY[i] = maxOff
                case .up:    tileOffsetY[i] = -maxOff
                }
            }
            i += 1
        }

        // Fade the merge highlights out as the merger happens.
        withAnimation(.easeOut(duration: 0.10)) {
            var k = 0
            while k < gridSize * gridSize {
                tileMergeGlow[k] = 0.0
                tileDestGlow[k] = 0.0
                k += 1
            }
        }

        game.saveUndoState()
        let moved = game.move(direction)
        if moved {
            game.spawnTilesForMove()
            // Once the model has settled the new grid, reset offsets — every
            // tile is now at its natural grid position.
            var j = 0
            while j < gridSize * gridSize {
                tileOffsetX[j] = 0.0
                tileOffsetY[j] = 0.0
                tileMaxAxisOffset[j] = 0.0
                j += 1
            }
            triggerAnimations()
            playMergeHaptics()
        }
        game.checkGameState()
        if game.isGameOver {
            playHaptic(.impact)
        }
        game.saveState()

        dragDirection = nil
        dragPreview = nil
    }

    /// User released without crossing the commit threshold — slide tiles back
    /// to their origin and fade highlights out.
    func cancelDrag() {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.78)) {
            var i = 0
            while i < gridSize * gridSize {
                tileOffsetX[i] = 0.0
                tileOffsetY[i] = 0.0
                tileMergeGlow[i] = 0.0
                tileDestGlow[i] = 0.0
                i += 1
            }
        }
        playHaptic(HapticPattern([HapticEvent(.tick, intensity: 0.28)]))
        dragDirection = nil
        dragPreview = nil
        // Clear max offsets after the cancel animation completes.
        animTimer?.invalidate()
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: false) { _ in
            clearTileMaxAxisOffset()
        }
    }

    func clearTileMaxAxisOffset() {
        var i = 0
        while i < gridSize * gridSize {
            tileMaxAxisOffset[i] = 0.0
            i += 1
        }
    }

    /// Z-order for a tile during a drag preview. Sliding tiles must render
    /// above the stationary cells they pass over (each cell's `tileView`
    /// paints its own background even when empty, so without lifting moving
    /// tiles they get covered by the empty-cell background of later siblings
    /// in the row/column iteration order). Absorbed-source tiles are lifted
    /// higher still so they render above the merge destination they're
    /// sliding into.
    func dragZIndex(for index: Int) -> Double {
        if tileMergeGlow[index] > 0.0 { return 2.0 }
        if tileMaxAxisOffset[index] > 0.0 { return 1.0 }
        return 0.0
    }

    // MARK: - Merge highlight overlay

    /// A "beautiful" highlight rendered over a tile during a drag preview.
    /// Tiles being *absorbed* (the source of a merge) get a bright gold
    /// border with an outer glow; tiles that will *receive* the merge get a
    /// softer accent border. Both fade in/out via withAnimation.
    @ViewBuilder
    func mergeHighlightOverlay(idx: Int, cellSize: Double) -> some View {
        let mergeGlow = tileMergeGlow[idx]
        let destGlow = tileDestGlow[idx]
        if mergeGlow > 0.0 || destGlow > 0.0 {
            ZStack {
                if destGlow > 0.0 {
                    RoundedRectangle(cornerRadius: tileCornerRadius)
                        .stroke(Color(red: 1.0, green: 0.92, blue: 0.55), lineWidth: 2.5)
                        .frame(width: cellSize, height: cellSize)
                        .opacity(destGlow * 0.9)
                }
                if mergeGlow > 0.0 {
                    RoundedRectangle(cornerRadius: tileCornerRadius)
                        .stroke(Color(red: 1.0, green: 0.83, blue: 0.30), lineWidth: 3.0)
                        .frame(width: cellSize, height: cellSize)
                        .shadow(color: Color(red: 1.0, green: 0.85, blue: 0.30).opacity(0.75 * mergeGlow), radius: 8.0)
                        .opacity(mergeGlow)
                    // Inner highlight ring for extra polish.
                    RoundedRectangle(cornerRadius: tileCornerRadius - 1.0)
                        .stroke(Color.white.opacity(0.55 * mergeGlow), lineWidth: 1.0)
                        .frame(width: cellSize - 4.0, height: cellSize - 4.0)
                }
            }
            .allowsHitTesting(false)
        } else {
            EmptyView()
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
                .foregroundStyle(theme.scoreBoxLabel)
            Text("\(value)")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(theme.scoreBoxValue)
                .monospaced()
        }
        .frame(minWidth: 80)
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.scoreBoxBackground)
        )
    }

    // MARK: - Tile

    func tileView(value: Int, cellSize: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: tileCornerRadius)
                .fill(value > 0 ? theme.tileColor(for: value) : Color.clear)
                .frame(width: cellSize, height: cellSize)

            if value > 0 {
                Text("\(value)")
                    .font(.system(size: tileFontSize(for: value, cellSize: cellSize), weight: .bold, design: .rounded))
                    .foregroundStyle(theme.tileForeground(for: value))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - HUD

    var hudView: some View {
        HStack(spacing: 8) {
            Button(action: { dismiss() }) {
                Image("cancel", bundle: .module)
                    .font(.title2)
                    .foregroundStyle(theme.hudForeground)
            }

            Spacer()

            HStack(spacing: 0) {
                Text("2048", bundle: .module)
                    .font(.title)
                    .fontWeight(.black)
                    .foregroundStyle(theme.hudForeground)
                if game.difficulty != .normal {
                    Text(" (\(game.difficulty.label))")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(game.difficulty.accentColor)
                }
            }

            Spacer()

            if game.difficulty.undoAllowed {
                Button(action: {
                    game.undo()
                    resetScales()
                    playHaptic(.snap)
                    game.saveState()
                }) {
                    HStack(spacing: 2) {
                        Image("undo", bundle: .module)
                            .font(.title2)
                        Text("\(game.undosRemaining)")
                            .font(.caption2)
                            .fontWeight(.bold)
                    }
                    .foregroundStyle(game.hasUndo && game.undosRemaining > 0 ? theme.hudForeground : theme.hudForeground.opacity(0.3))
                }
                .disabled(!game.hasUndo || game.undosRemaining <= 0)
            }

            Button(action: { showPauseMenu = true }) {
                Image("pause_circle", bundle: .module)
                    .font(.title2)
                    .foregroundStyle(theme.hudForeground)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.hudBackground)
    }

    // MARK: - Win Overlay

    func winOverlay(boardSize: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tile2048.opacity(0.65))
                .frame(width: boardSize, height: boardSize)

            VStack(spacing: 16) {
                Text("You Win!", bundle: .module)
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundStyle(Color.white)

                Text("Score: \(displayedScore)")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.white)
                    .monospaced()

                Button(action: {
                    game.continueGame()
                }) {
                    Text("Keep Going", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                        .frame(width: 160, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.boardBackground)
                        )
                }
                .buttonStyle(.plain)

                Button(action: {
                    showDifficultyPicker = true
                }) {
                    Text("New Game", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                        .frame(width: 160, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.boardBackground)
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
                .fill(theme.background.opacity(0.85))
                .frame(width: boardSize, height: boardSize)

            VStack(spacing: 16) {
                Text("Game Over!", bundle: .module)
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundStyle(theme.hudForeground)

                VStack(spacing: 4) {
                    Text("Score", bundle: .module)
                        .font(.headline)
                        .foregroundStyle(theme.hudForeground.opacity(0.7))
                    Text("\(displayedScore)")
                        .font(.system(size: 44))
                        .fontWeight(.bold)
                        .foregroundStyle(theme.hudForeground)
                        .monospaced()
                }

                if game.score >= game.highScore && game.score > 0 {
                    Text("New High Score!", bundle: .module)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(theme.tile64)
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
                                .fill(theme.boardBackground)
                        )
                }
                .buttonStyle(.plain)

                ShareLink(
                    item: "I scored \(game.score) in 2048 on Faire Games! Can you beat it?\nhttps://appfair.net",
                    subject: Text("2048 Score", bundle: .module),
                    message: Text("I scored \(game.score) in 2048!")
                ) {
                    Label { Text("Share", bundle: .module) } icon: { Image(systemName: "square.and.arrow.up") }
                        .font(.subheadline)
                        .foregroundStyle(theme.hudForeground.opacity(0.7))
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

// MARK: - Difficulty Picker

struct TwentyFortyEightDifficultyPickerView: View {
    let theme: TwentyFortyEightTheme
    let onSelect: (TwentyFortyEightDifficulty) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Text("Choose Difficulty", bundle: .module)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(theme.hudForeground)
                        .padding(.top, 10)

                    ForEach([TwentyFortyEightDifficulty.easy, TwentyFortyEightDifficulty.normal, TwentyFortyEightDifficulty.hard], id: \.rawValue) { d in
                        Button(action: {
                            onSelect(d)
                            dismiss()
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(d.label)
                                        .font(.title3)
                                        .fontWeight(.bold)
                                        .foregroundStyle(theme.hudForeground)
                                    Text(d.description)
                                        .font(.caption)
                                        .foregroundStyle(theme.hudForeground.opacity(0.75))
                                }
                                Spacer()
                            }
                            .padding(16)
                            .background(d.accentColor.opacity(0.12))
                            .cornerRadius(14.0)
                            .padding(1.0)
                            .background(d.accentColor.opacity(0.4))
                            .cornerRadius(15.0)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background.ignoresSafeArea())
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
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }
}

// MARK: - Settings

struct TwentyFortyEightSettingsView: View {
    @Bindable var settings: TwentyFortyEightSettings
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("2048", bundle: .module)) {
                    Toggle(isOn: $settings.vibrations) { Text("Vibrations", bundle: .module) }
                }
                Section(header: Text("Theme", bundle: .module)) {
                    ForEach(TwentyFortyEightTheme.all, id: \.id) { t in
                        TwentyFortyEightThemeRow(
                            theme: t,
                            isSelected: t.id == settings.themeID,
                            onTap: { settings.themeID = t.id }
                        )
                    }
                }
                Section(header: Text("Data", bundle: .module)) {
                    Button(role: .destructive, action: {
                        resetTwentyFortyEightHighScore()
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

/// A single row in the theme picker showing the localized name and a
/// palette-preview made of mini "tile" swatches. The whole row is tappable.
struct TwentyFortyEightThemeRow: View {
    let theme: TwentyFortyEightTheme
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ThemePalettePreview(theme: theme)
                VStack(alignment: .leading, spacing: 2) {
                    theme.nameText()
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    if theme.isDark {
                        Text("Dark", bundle: .module, comment: "Subtitle under a dark-mode theme name in the 2048 theme picker")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Light", bundle: .module, comment: "Subtitle under a light-mode theme name in the 2048 theme picker")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                }
            }
            #if !SKIP
            .contentShape(Rectangle())
            #endif
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("theme.row.\(theme.id)")
    }
}

/// Mini board preview shown next to a theme's name in the picker. Renders the
/// theme's board background framing a 2×3 grid of tile swatches drawn from the
/// theme's actual tile colors so the user sees the real palette they'll get.
struct ThemePalettePreview: View {
    let theme: TwentyFortyEightTheme

    var body: some View {
        let swatches = theme.previewSwatches
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.boardBackground)
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    swatch(swatches[0])
                    swatch(swatches[1])
                    swatch(swatches[2])
                }
                HStack(spacing: 2) {
                    swatch(swatches[3])
                    swatch(swatches[4])
                    swatch(theme.tileBeyondColor)
                }
            }
            .padding(4)
        }
        .frame(width: 56, height: 40)
    }

    private func swatch(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@Observable
public class TwentyFortyEightSettings {
    public var vibrations: Bool = defaults.value(forKey: "twentyfortyeightVibrations", default: true) {
        didSet { defaults.set(vibrations, forKey: "twentyfortyeightVibrations") }
    }

    public var themeID: String = defaults.value(forKey: "twentyfortyeightThemeID", default: TwentyFortyEightTheme.classic.id) {
        didSet { defaults.set(themeID, forKey: "twentyfortyeightThemeID") }
    }

    public var theme: TwentyFortyEightTheme {
        return TwentyFortyEightTheme.theme(forID: themeID)
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
