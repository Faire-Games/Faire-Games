// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import Observation
import SkipKit

public struct TetrisContainerView: View {
    @State private var settings = TetrisSettings()

    public init() { }

    public var body: some View {
        TetrisGameView()
            .navigationTitle("")
            #if !os(macOS)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .colorScheme(.dark)
            #endif
            .environment(settings)
    }
}

// MARK: - Cell Position

/// A row/col coordinate on the board. Uses `final class` for reliable transpilation.
final class CellPos: Sendable {
    let r: Int
    let c: Int
    init(_ r: Int, _ c: Int) { self.r = r; self.c = c }
}

// MARK: - Tetromino Definitions

/// The seven standard Tetris tetrominoes.
/// Raw values 0–6 are stored in the board grid to track placed block colors.
enum TetrominoKind: Int, CaseIterable {
    case i = 0, o, t, s, z, j, l

    /// Cell offsets for each of the four rotations.
    static let rotationTable: [[[CellPos]]] = buildRotationTable()

    private static func buildRotationTable() -> [[[CellPos]]] {
        var table: [[[CellPos]]] = []
        for kind in TetrominoKind.allCases {
            table.append(kind.rawRotations())
        }
        return table
    }

    private func rawRotations() -> [[CellPos]] {
        switch self {
        case .i: return [
            [CellPos(0, -1), CellPos(0, 0), CellPos(0, 1), CellPos(0, 2)],
            [CellPos(-1, 0), CellPos(0, 0), CellPos(1, 0), CellPos(2, 0)],
            [CellPos(0, -1), CellPos(0, 0), CellPos(0, 1), CellPos(0, 2)],
            [CellPos(-1, 0), CellPos(0, 0), CellPos(1, 0), CellPos(2, 0)]
        ]
        case .o: return [
            [CellPos(0, 0), CellPos(0, 1), CellPos(1, 0), CellPos(1, 1)],
            [CellPos(0, 0), CellPos(0, 1), CellPos(1, 0), CellPos(1, 1)],
            [CellPos(0, 0), CellPos(0, 1), CellPos(1, 0), CellPos(1, 1)],
            [CellPos(0, 0), CellPos(0, 1), CellPos(1, 0), CellPos(1, 1)]
        ]
        case .t: return [
            [CellPos(0, -1), CellPos(0, 0), CellPos(0, 1), CellPos(-1, 0)],
            [CellPos(-1, 0), CellPos(0, 0), CellPos(1, 0), CellPos(0, 1)],
            [CellPos(0, -1), CellPos(0, 0), CellPos(0, 1), CellPos(1, 0)],
            [CellPos(-1, 0), CellPos(0, 0), CellPos(1, 0), CellPos(0, -1)]
        ]
        case .s: return [
            [CellPos(0, -1), CellPos(0, 0), CellPos(-1, 0), CellPos(-1, 1)],
            [CellPos(-1, 0), CellPos(0, 0), CellPos(0, 1), CellPos(1, 1)],
            [CellPos(0, -1), CellPos(0, 0), CellPos(-1, 0), CellPos(-1, 1)],
            [CellPos(-1, 0), CellPos(0, 0), CellPos(0, 1), CellPos(1, 1)]
        ]
        case .z: return [
            [CellPos(-1, -1), CellPos(-1, 0), CellPos(0, 0), CellPos(0, 1)],
            [CellPos(0, 0), CellPos(1, 0), CellPos(0, 1), CellPos(-1, 1)],
            [CellPos(-1, -1), CellPos(-1, 0), CellPos(0, 0), CellPos(0, 1)],
            [CellPos(0, 0), CellPos(1, 0), CellPos(0, 1), CellPos(-1, 1)]
        ]
        case .j: return [
            [CellPos(-1, -1), CellPos(0, -1), CellPos(0, 0), CellPos(0, 1)],
            [CellPos(-1, 0), CellPos(0, 0), CellPos(1, 0), CellPos(-1, 1)],
            [CellPos(0, -1), CellPos(0, 0), CellPos(0, 1), CellPos(1, 1)],
            [CellPos(1, 0), CellPos(0, 0), CellPos(-1, 0), CellPos(1, -1)]
        ]
        case .l: return [
            [CellPos(0, -1), CellPos(0, 0), CellPos(0, 1), CellPos(-1, 1)],
            [CellPos(-1, 0), CellPos(0, 0), CellPos(1, 0), CellPos(1, 1)],
            [CellPos(0, -1), CellPos(0, 0), CellPos(0, 1), CellPos(1, -1)],
            [CellPos(-1, -1), CellPos(-1, 0), CellPos(0, 0), CellPos(1, 0)]
        ]
        }
    }

    func offsets(rotation: Int) -> [CellPos] {
        return TetrominoKind.rotationTable[self.rawValue][rotation]
    }

    // Bright face color
    var color: Color {
        switch self {
        case .i: return Color(red: 0.2, green: 0.88, blue: 0.92)
        case .o: return Color(red: 0.96, green: 0.88, blue: 0.28)
        case .t: return Color(red: 0.72, green: 0.34, blue: 0.85)
        case .s: return Color(red: 0.3, green: 0.88, blue: 0.42)
        case .z: return Color(red: 0.92, green: 0.28, blue: 0.28)
        case .j: return Color(red: 0.3, green: 0.45, blue: 0.92)
        case .l: return Color(red: 0.96, green: 0.6, blue: 0.2)
        }
    }

    // Light highlight color (top/left edges for 3D bevel)
    var highlightColor: Color {
        switch self {
        case .i: return Color(red: 0.55, green: 0.96, blue: 0.98)
        case .o: return Color(red: 0.99, green: 0.96, blue: 0.6)
        case .t: return Color(red: 0.86, green: 0.6, blue: 0.95)
        case .s: return Color(red: 0.6, green: 0.96, blue: 0.65)
        case .z: return Color(red: 0.97, green: 0.55, blue: 0.55)
        case .j: return Color(red: 0.55, green: 0.65, blue: 0.97)
        case .l: return Color(red: 0.99, green: 0.78, blue: 0.48)
        }
    }

    // Dark shadow color (bottom/right edges for 3D bevel)
    var shadowColor: Color {
        switch self {
        case .i: return Color(red: 0.05, green: 0.55, blue: 0.58)
        case .o: return Color(red: 0.6, green: 0.52, blue: 0.08)
        case .t: return Color(red: 0.4, green: 0.12, blue: 0.5)
        case .s: return Color(red: 0.08, green: 0.5, blue: 0.15)
        case .z: return Color(red: 0.55, green: 0.1, blue: 0.1)
        case .j: return Color(red: 0.1, green: 0.18, blue: 0.55)
        case .l: return Color(red: 0.6, green: 0.32, blue: 0.06)
        }
    }

    static func colorForRaw(_ raw: Int) -> Color {
        return (TetrominoKind(rawValue: raw) ?? TetrominoKind.t).color
    }

    static func highlightForRaw(_ raw: Int) -> Color {
        return (TetrominoKind(rawValue: raw) ?? TetrominoKind.t).highlightColor
    }

    static func shadowForRaw(_ raw: Int) -> Color {
        return (TetrominoKind(rawValue: raw) ?? TetrominoKind.t).shadowColor
    }
}

// MARK: - Game Model

@Observable final class TetrisModel {
    static let rows = 20
    static let cols = 10

    /// Board grid: -1 = empty, 0–6 = tetromino kind raw value
    var grid: [[Int]] = Array(repeating: Array(repeating: -1, count: 10), count: 20)
    var currentKind: TetrominoKind = TetrominoKind.t
    var currentRotation: Int = 0
    var currentRow: Int = 0
    var currentCol: Int = 4
    var nextPieces: [TetrominoKind] = []
    var score: Int = 0
    var highScore: Int = 0
    var level: Int = 1
    var totalLinesCleared: Int = 0
    var isGameOver: Bool = false
    var isPaused: Bool = false
    var clearingRows: [Int] = []
    var isClearingAnimation: Bool = false
    var lastClearCount: Int = 0
    var ghostRow: Int = 0

    private var bag: [TetrominoKind] = []

    init() {
        loadHighScore()
        fillBag()
        // Fill the 3-piece preview queue
        nextPieces = [nextFromBag(), nextFromBag(), nextFromBag()]
        spawnPiece()
    }

    // MARK: Current Piece Helpers

    func currentCells() -> [CellPos] {
        let offsets = currentKind.offsets(rotation: currentRotation)
        var result: [CellPos] = []
        for o in offsets {
            result.append(CellPos(currentRow + o.r, currentCol + o.c))
        }
        return result
    }

    func ghostCells() -> [CellPos] {
        let dr = ghostRow - currentRow
        let offsets = currentKind.offsets(rotation: currentRotation)
        var result: [CellPos] = []
        for o in offsets {
            result.append(CellPos(currentRow + o.r + dr, currentCol + o.c))
        }
        return result
    }

    // MARK: Random Bag (7-piece system)

    private func fillBag() {
        var pieces = TetrominoKind.allCases
        var i = pieces.count - 1
        while i > 0 {
            let j = Int.random(in: 0...i)
            let tmp = pieces[i]
            pieces[i] = pieces[j]
            pieces[j] = tmp
            i -= 1
        }
        bag = pieces
    }

    private func nextFromBag() -> TetrominoKind {
        if bag.isEmpty { fillBag() }
        return bag.removeFirst()
    }

    // MARK: Spawning

    func spawnPiece() {
        // Take the first from the preview queue and refill
        currentKind = nextPieces[0]
        nextPieces.removeFirst()
        nextPieces.append(nextFromBag())

        currentRotation = 0
        currentRow = 0
        currentCol = 4

        let offsets = currentKind.offsets(rotation: 0)
        var minR = offsets[0].r
        for o in offsets { if o.r < minR { minR = o.r } }
        if minR > 0 { currentRow = currentRow - minR }

        updateGhost()

        if !isValidPosition(row: currentRow, col: currentCol, rotation: currentRotation, kind: currentKind) {
            isGameOver = true
            if score > highScore {
                highScore = score
                saveHighScore()
            }
        }
    }

    // MARK: Validation

    func isValidPosition(row: Int, col: Int, rotation: Int, kind: TetrominoKind) -> Bool {
        let offsets = kind.offsets(rotation: rotation)
        for o in offsets {
            let r = row + o.r
            let c = col + o.c
            if c < 0 || c >= TetrisModel.cols { return false }
            if r >= TetrisModel.rows { return false }
            if r >= 0 && grid[r][c] != -1 { return false }
        }
        return true
    }

    // MARK: Ghost

    func updateGhost() {
        var testRow = currentRow
        while isValidPosition(row: testRow + 1, col: currentCol, rotation: currentRotation, kind: currentKind) {
            testRow += 1
        }
        ghostRow = testRow
    }

    // MARK: Movement

    func moveLeft() -> Bool {
        if isValidPosition(row: currentRow, col: currentCol - 1, rotation: currentRotation, kind: currentKind) {
            currentCol -= 1
            updateGhost()
            return true
        }
        return false
    }

    func moveRight() -> Bool {
        if isValidPosition(row: currentRow, col: currentCol + 1, rotation: currentRotation, kind: currentKind) {
            currentCol += 1
            updateGhost()
            return true
        }
        return false
    }

    func moveDown() -> Bool {
        if isValidPosition(row: currentRow + 1, col: currentCol, rotation: currentRotation, kind: currentKind) {
            currentRow += 1
            return true
        }
        return false
    }

    func rotate() -> Bool {
        let newRot = (currentRotation + 1) % 4
        if isValidPosition(row: currentRow, col: currentCol, rotation: newRot, kind: currentKind) {
            currentRotation = newRot
            updateGhost()
            return true
        }
        let kicks = [1, -1, 2, -2]
        for kick in kicks {
            if isValidPosition(row: currentRow, col: currentCol + kick, rotation: newRot, kind: currentKind) {
                currentCol += kick
                currentRotation = newRot
                updateGhost()
                return true
            }
        }
        return false
    }

    // MARK: Lock & Clear

    func lockPiece() {
        let cells = currentCells()
        for cell in cells {
            let r = cell.r
            let c = cell.c
            if r >= 0 && r < TetrisModel.rows && c >= 0 && c < TetrisModel.cols {
                grid[r][c] = currentKind.rawValue
            }
        }
    }

    func findFullRows() -> [Int] {
        var full: [Int] = []
        for r in 0..<TetrisModel.rows {
            var isFull = true
            for c in 0..<TetrisModel.cols {
                if grid[r][c] == -1 { isFull = false; break }
            }
            if isFull { full.append(r) }
        }
        return full
    }

    func removeRows(_ rows: [Int]) {
        let sorted = rows.sorted()
        for r in sorted {
            var rr = r
            while rr > 0 {
                grid[rr] = grid[rr - 1]
                rr -= 1
            }
            grid[0] = Array(repeating: -1, count: TetrisModel.cols)
        }
    }

    func addScore(linesCount: Int, dropBonus: Int) {
        let basePoints: Int
        switch linesCount {
        case 1: basePoints = 100
        case 2: basePoints = 300
        case 3: basePoints = 500
        case 4: basePoints = 800
        default: basePoints = 0
        }
        score += basePoints * level + dropBonus * 2
        totalLinesCleared += linesCount
        lastClearCount = linesCount

        let newLevel = (totalLinesCleared / 10) + 1
        if newLevel > level {
            level = min(newLevel, 15)
        }

        if score > highScore {
            highScore = score
            saveHighScore()
        }
    }

    // MARK: Tick Speed

    var tickInterval: Double {
        let base = 0.8
        let speed = base - (Double(level - 1) * 0.045)
        if speed < 0.1 { return 0.1 }
        return speed
    }

    // MARK: New Game

    func newGame() {
        grid = Array(repeating: Array(repeating: -1, count: TetrisModel.cols), count: TetrisModel.rows)
        score = 0
        level = 1
        totalLinesCleared = 0
        isGameOver = false
        isPaused = false
        clearingRows = []
        isClearingAnimation = false
        lastClearCount = 0
        bag = []
        fillBag()
        nextPieces = [nextFromBag(), nextFromBag(), nextFromBag()]
        spawnPiece()
    }

    // MARK: Persistence

    private func saveHighScore() {
        UserDefaults.standard.set(highScore, forKey: "tetris_highscore")
    }

    func loadHighScore() {
        highScore = UserDefaults.standard.integer(forKey: "tetris_highscore")
    }

    /// Resets the persisted high score to zero.
    static func resetHighScore() {
        UserDefaults.standard.set(0, forKey: "tetris_highscore")
    }
}

/// Resets the Tetris high score to zero.
public func resetTetrisHighScore() {
    TetrisModel.resetHighScore()
}

// MARK: - Game View

struct TetrisGameView: View {
    @State var game = TetrisModel()
    @State var tickTimer: Timer? = nil
    @State var dragAccumulatedX: CGFloat = 0.0
    @State var dragAccumulatedY: CGFloat = 0.0
    @State var showClearEffect: Bool = false
    @State var clearEffectText: String = ""
    @State var showSettings: Bool = false
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase
    @Environment(TetrisSettings.self) var settings: TetrisSettings

    func playHaptic(_ pattern: HapticPattern) {
        if settings.vibrations {
            HapticFeedback.play(pattern)
        }
    }

    var body: some View {
        GeometryReader { geo in
            // Reserve space for header (~36), stats (~50), padding (~20)
            let chromeHeight: CGFloat = 110
            let maxCellFromHeight = (geo.size.height - chromeHeight) / CGFloat(TetrisModel.rows)
            let maxCellFromWidth = (geo.size.width - 16) / CGFloat(TetrisModel.cols)
            let cellSize = max(min(maxCellFromWidth, maxCellFromHeight), 8.0)

            ZStack {
                // Background
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.06, blue: 0.18),
                        Color(red: 0.02, green: 0.02, blue: 0.08)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header
                    headerView
                        .padding(.bottom, 4)

                    // Stats row with next piece preview
                    statsRow(cellSize: cellSize)
                        .padding(.bottom, 6)

                    // Game board — full width
                    boardView(cellSize: cellSize)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                if game.isGameOver {
                    gameOverOverlay
                }

                if game.isPaused && !game.isGameOver {
                    pauseOverlay
                }

                if showClearEffect {
                    clearPopup
                }
            }
        }
        .navigationBarBackButtonHidden()
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase != .active && !game.isGameOver && !game.isPaused {
                game.isPaused = true
                stopTimer()
            }
        }
        .sheet(isPresented: $showSettings) {
            TetrisSettingsView(settings: settings)
        }
    }

    // MARK: - Header

    var headerView: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Image("cancel", bundle: .module)
                    .font(.title2)
                    .foregroundStyle(Color.white.opacity(0.6))
            }

            Spacer()

            Text("SIRTET")
                .font(.headline)
                .fontWeight(.black)
                .foregroundStyle(Color.white)
            Spacer()

            Button(action: {
                game.isPaused.toggle()
                if game.isPaused {
                    stopTimer()
                } else {
                    startTimer()
                }
            }) {
                Image(game.isPaused ? "play_circle" : "pause_circle", bundle: .module)
                    .font(.title2)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Stats Row

    func statsRow(cellSize: CGFloat) -> some View {
        HStack(spacing: 0) {
            statBox(label: "SCORE", value: "\(game.score)")
            Spacer()
            statBox(label: "LEVEL", value: "\(game.level)")
            Spacer()
            nextPiecePreview(cellSize: cellSize * 0.45)
            Spacer()
            statBox(label: "LINES", value: "\(game.totalLinesCleared)")
            Spacer()
            statBox(label: "HIGH", value: "\(game.highScore)")
        }
        .padding(.horizontal, 4)
    }

    func statBox(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(Color.white.opacity(0.5))
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(Color.white)
                .monospaced()
        }
    }

    // MARK: - Board

    func boardView(cellSize: CGFloat) -> some View {
        let ghostPositions = game.ghostCells()
        let currentPositions = game.currentCells()

        return ZStack {
            // Board background with subtle border
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: 0.04, green: 0.04, blue: 0.08))
                .frame(
                    width: cellSize * CGFloat(TetrisModel.cols) + 4,
                    height: cellSize * CGFloat(TetrisModel.rows) + 4
                )

            VStack(spacing: 0) {
                ForEach(0..<TetrisModel.rows, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(0..<TetrisModel.cols, id: \.self) { c in
                            singleCell(
                                row: r, col: c, cellSize: cellSize,
                                ghostPositions: ghostPositions,
                                currentPositions: currentPositions
                            )
                        }
                    }
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { value in handleDrag(value: value, cellSize: cellSize) }
                .onEnded { _ in handleDragEnd() }
        )
        .onTapGesture { handleTap() }
    }

    // MARK: - 3D Block Cell

    func singleCell(row: Int, col: Int, cellSize: CGFloat, ghostPositions: [CellPos], currentPositions: [CellPos]) -> some View {
        let gridVal = game.grid[row][col]
        let isClearing = game.clearingRows.contains(row)
        let isGhost = ghostPositions.contains(where: { $0.r == row && $0.c == col })
        let isCurrent = currentPositions.contains(where: { $0.r == row && $0.c == col })

        let isBlock = isCurrent || (gridVal != -1 && !isClearing)
        let blockKindRaw = isCurrent ? game.currentKind.rawValue : gridVal
        let inset = cellSize * 0.08
        let cornerR = cellSize * 0.18

        return ZStack {
            if isClearing && gridVal != -1 {
                // Flash white during clearing animation
                RoundedRectangle(cornerRadius: cornerR)
                    .fill(Color.white)
                    .frame(width: cellSize - 1, height: cellSize - 1)
                    .opacity(0.8)
            } else if isBlock {
                // Shadow base layer
                RoundedRectangle(cornerRadius: cornerR)
                    .fill(TetrominoKind.shadowForRaw(blockKindRaw))
                    .frame(width: cellSize - 1, height: cellSize - 1)

                // Main face with subtle gradient for soft 3D look
                RoundedRectangle(cornerRadius: cornerR)
                    .fill(
                        LinearGradient(
                            colors: [
                                TetrominoKind.highlightForRaw(blockKindRaw).opacity(0.5),
                                TetrominoKind.colorForRaw(blockKindRaw)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: cellSize - 2, height: cellSize - 2)
            } else if isGhost {
                RoundedRectangle(cornerRadius: cornerR)
                    .fill(game.currentKind.color.opacity(0.12))
                    .frame(width: cellSize - 1, height: cellSize - 1)
                    .border(game.currentKind.color.opacity(0.25), width: 0.5)
            } else {
                // Empty cell
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: 0.07, green: 0.07, blue: 0.12))
                    .frame(width: cellSize - 1, height: cellSize - 1)
                    .border(Color(red: 0.1, green: 0.1, blue: 0.15), width: 0.25)
            }
        }
        .frame(width: cellSize, height: cellSize)
    }

    // MARK: - Next Piece Preview

    func nextPiecePreview(cellSize: CGFloat) -> some View {
        let kind = game.nextPieces.first
        let offsets = kind?.offsets(rotation: 0) ?? []

        var minR = offsets.first?.r ?? 0; var maxR = minR
        var minC = offsets.first?.c ?? 0; var maxC = minC
        for o in offsets {
            if o.r < minR { minR = o.r }
            if o.r > maxR { maxR = o.r }
            if o.c < minC { minC = o.c }
            if o.c > maxC { maxC = o.c }
        }
        let previewRows = max(maxR - minR + 1, 1)
        let previewCols = max(maxC - minC + 1, 1)
        // Fixed dimensions: tallest piece is 2 rows, widest is 4 cols (I-piece)
        let maxRows = 2
        let maxCols = 4
        let cornerR = cellSize * 0.18
        // Capture colors once to avoid per-cell optional chaining issues on Android
        let blockColor = kind?.color ?? Color.clear
        let blockShadow = kind?.shadowColor ?? Color.clear
        let blockHighlight = kind?.highlightColor ?? Color.clear

        return VStack(spacing: 1) {
            Text("NEXT")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(Color.white.opacity(0.5))
            ZStack {
                // Fixed-size invisible frame so the area never resizes
                Color.clear
                    .frame(width: cellSize * CGFloat(maxCols), height: cellSize * CGFloat(maxRows))
                VStack(spacing: 0) {
                    ForEach(0..<previewRows, id: \.self) { r in
                        HStack(spacing: 0) {
                            ForEach(0..<previewCols, id: \.self) { c in
                                let hasBlock = offsets.contains(where: { $0.r == r + minR && $0.c == c + minC })
                                ZStack {
                                    if hasBlock {
                                        RoundedRectangle(cornerRadius: cornerR)
                                            .fill(blockShadow)
                                            .frame(width: cellSize - 1, height: cellSize - 1)
                                        RoundedRectangle(cornerRadius: cornerR)
                                            .fill(
                                                LinearGradient(
                                                    colors: [
                                                        blockHighlight.opacity(0.5),
                                                        blockColor
                                                    ],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                )
                                            )
                                            .frame(width: cellSize - 2, height: cellSize - 2)
                                    }
                                }
                                .frame(width: cellSize, height: cellSize)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Gestures

    func handleTap() {
        guard !game.isGameOver && !game.isPaused else { return }
        if game.rotate() {
            playHaptic(.snap)
        }
    }

    func handleDrag(value: DragGesture.Value, cellSize: CGFloat) {
        guard !game.isGameOver && !game.isPaused else { return }

        let dx = value.translation.width
        let dy = value.translation.height

        let threshold = cellSize * 0.8
        let totalDx = dx - dragAccumulatedX
        let colsMoved = Int(totalDx / threshold)
        if colsMoved != 0 {
            var moved = false
            let dir = colsMoved > 0 ? 1 : -1
            var steps = colsMoved
            if steps < 0 { steps = -steps }
            for _ in 0..<steps {
                if dir > 0 {
                    if game.moveRight() { moved = true }
                } else {
                    if game.moveLeft() { moved = true }
                }
            }
            if moved {
                playHaptic(.snap)
            }
            dragAccumulatedX += CGFloat(colsMoved) * threshold
        }

        // Downward drag: move one row per threshold
        let totalDy = dy - dragAccumulatedY
        if totalDy > cellSize {
            let rowsToMove = Int(totalDy / cellSize)
            for _ in 0..<rowsToMove {
                if game.moveDown() {
                    game.addScore(linesCount: 0, dropBonus: 1)
                }
            }
            dragAccumulatedY += CGFloat(rowsToMove) * cellSize
        }
    }

    func handleDragEnd() {
        dragAccumulatedX = 0.0
        dragAccumulatedY = 0.0
    }

    // MARK: - Timer

    func startTimer() {
        stopTimer()
        let interval = game.tickInterval
        tickTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            tick()
        }
    }

    func stopTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    func tick() {
        guard !game.isGameOver && !game.isPaused && !game.isClearingAnimation else { return }
        if !game.moveDown() {
            lockAndClear(dropBonus: 0)
        }
    }

    func lockAndClear(dropBonus: Int) {
        game.lockPiece()

        let fullRows = game.findFullRows()
        if !fullRows.isEmpty {
            game.isClearingAnimation = true
            game.clearingRows = fullRows

            if fullRows.count >= 4 {
                playHaptic(.bigCelebrate)
                clearEffectText = "SIRTET!" // "TETRIS!"
            } else if fullRows.count == 3 {
                playHaptic(.celebrate)
                clearEffectText = "TRIPLE"
            } else if fullRows.count == 2 {
                playHaptic(.celebrate)
                clearEffectText = "DOUBLE"
            } else {
                playHaptic(.snap)
                clearEffectText = "SINGLE"
            }
            showClearEffect = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                game.removeRows(fullRows)
                game.addScore(linesCount: fullRows.count, dropBonus: dropBonus)
                game.clearingRows = []
                game.isClearingAnimation = false
                game.spawnPiece()
                startTimer()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                showClearEffect = false
            }
        } else {
            game.addScore(linesCount: 0, dropBonus: dropBonus)
            playHaptic(.place)
            game.spawnPiece()
            startTimer()
        }

        if game.isGameOver {
            stopTimer()
            playHaptic(.error)
        }
    }

    // MARK: - Game Over Overlay

    var gameOverOverlay: some View {
        ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("GAME OVER")
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundStyle(Color.white)

                VStack(spacing: 4) {
                    Text("Score")
                        .font(.headline)
                        .foregroundStyle(Color.white.opacity(0.7))
                    Text("\(game.score)")
                        .font(.system(size: 44))
                        .fontWeight(.bold)
                        .foregroundStyle(Color.yellow)
                        .monospaced()
                }

                HStack(spacing: 24) {
                    VStack(spacing: 2) {
                        Text("Level")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.6))
                        Text("\(game.level)")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.white)
                    }
                    VStack(spacing: 2) {
                        Text("Lines")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.6))
                        Text("\(game.totalLinesCleared)")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.white)
                    }
                }

                if game.score >= game.highScore && game.score > 0 {
                    Text("New High Score!")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.yellow)
                }

                Button(action: {
                    game.newGame()
                    startTimer()
                }) {
                    Text("Play Again")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                        .frame(width: 180, height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(red: 0.2, green: 0.5, blue: 0.9))
                        )
                }
                .padding(.top, 4)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(red: 0.1, green: 0.1, blue: 0.2))
            )
        }
    }

    // MARK: - Pause Overlay

    var pauseOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Text("PAUSED")
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundStyle(Color.white)

                Button(action: {
                    game.isPaused = false
                    startTimer()
                }) {
                    Text("Resume")
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
                    game.newGame()
                    startTimer()
                }) {
                    Text("New Game")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(width: 160, height: 44)
                        .border(Color.white.opacity(0.3), width: 1)
                        .cornerRadius(12)
                }

                Button(action: { showSettings = true }) {
                    Text("Settings")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(width: 160, height: 44)
                        .border(Color.white.opacity(0.3), width: 1)
                        .cornerRadius(12)
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
                    .fill(Color(red: 0.1, green: 0.1, blue: 0.2))
            )
        }
    }

    // MARK: - Clear Popup

    var clearPopup: some View {
        VStack {
            Spacer()
            Text(clearEffectText)
                .font(.title)
                .fontWeight(.black)
                .foregroundStyle(game.lastClearCount >= 4 ? Color.yellow : Color.white)
                .shadow(color: Color.blue.opacity(0.8), radius: 12)
                .padding(.bottom, 100)
        }
    }
}

// MARK: - Preview Icon

/// Returns the TetrominoKind for a Tetris preview icon cell, or nil if empty.
/// Uses an 8x8 grid with pieces positioned to look appealing as a square icon.
private func tetrisPreviewKind(row: Int, col: Int) -> TetrominoKind? {
    // Bottom row - full line (I-piece cyan)
    if row == 7 && col >= 1 && col <= 6 { return .i }
    // L-piece (orange)
    if row == 6 && col >= 1 && col <= 3 { return .l }
    if row == 5 && col == 1 { return .l }
    // S-piece (green)
    if row == 6 && (col == 4 || col == 5) { return .s }
    if row == 5 && (col == 5 || col == 6) { return .s }
    // T-piece (purple)
    if row == 5 && col >= 2 && col <= 4 { return .t }
    if row == 4 && col == 3 { return .t }
    // Falling I-piece (cyan)
    if col == 4 && row >= 1 && row <= 4 { return .i }
    return nil
}

/// A preview icon for the Tetris game, using the same 3D cell rendering as the game.
public struct TetrisPreviewIcon: View {
    public init() { }

    public var body: some View {
        GeometryReader { geo in
            let gridSize = 8
            let padding: CGFloat = 4
            let available = min(geo.size.width, geo.size.height) - padding * 2
            let cellSize = available / CGFloat(gridSize)
            let cornerR = cellSize * 0.18

            VStack(spacing: 0) {
                ForEach(0..<gridSize, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<gridSize, id: \.self) { col in
                            let kind = tetrisPreviewKind(row: row, col: col)
                            ZStack {
                                if let kind = kind {
                                    // Shadow base layer — same as singleCell in game
                                    RoundedRectangle(cornerRadius: cornerR)
                                        .fill(kind.shadowColor)
                                        .frame(width: cellSize - 1, height: cellSize - 1)
                                    // Main face with gradient — same as singleCell in game
                                    RoundedRectangle(cornerRadius: cornerR)
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    kind.highlightColor.opacity(0.5),
                                                    kind.color
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                        )
                                        .frame(width: cellSize - 2, height: cellSize - 2)
                                }
                            }
                            .frame(width: cellSize, height: cellSize)
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
                .fill(Color(red: 0.08, green: 0.08, blue: 0.18))
        )
    }
}

// MARK: - In-Game Settings Sheet

struct TetrisSettingsView: View {
    @Bindable var settings: TetrisSettings
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Sirtet") {
                    Toggle("Vibrations", isOn: $settings.vibrations)
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

/// Settings specific to the Sirtet (Tetris) game.
@Observable
public class TetrisSettings {
    /// Whether vibrations (haptic feedback) are enabled for Sirtet.
    public var vibrations: Bool = defaults.value(forKey: "tetrisVibrations", default: true) {
        didSet { defaults.set(vibrations, forKey: "tetrisVibrations") }
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
