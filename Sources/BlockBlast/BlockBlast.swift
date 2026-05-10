// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import Observation
import SkipKit
import SkipModel
import FaireGamesModel

private let boardClearBonus: Int = 200

public struct BlockBlastContainerView: View {
    @State private var settings = BlockBlastSettings()
    @State private var showInstructions: Bool = false
    private let instructionsConfig = GameInstructionsConfig(
        key: "BlockBlast.instructions",
        bundle: .module,
        firstLaunchKey: "instructionsShown_BlockBlast",
        title: "Block Blast!"
    )

    public init() { }

    public var body: some View {
        BlockBlastGameView(showInstructions: $showInstructions)
            .navigationTitle("")
            #if !os(macOS)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .colorScheme(.dark)
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

/// A mini block blast game
struct BlockBlastGameView: View {
    @Binding var showInstructions: Bool
    @State var game = GameModel()
    @State var dragPieceIndex: Int = -1
    @State var dragOffset: CGSize = CGSize.zero
    @State var dragLocation: CGPoint = CGPoint.zero
    @State var isDragging: Bool = false
    @State var highlightRow: Int = -1
    @State var highlightCol: Int = -1
    @State var highlightValid: Bool = false
    @State var boardOrigin: CGPoint = CGPoint.zero
    @State var cellSize: CGFloat = 0
    @State var showCombo: Bool = false
    @State var prevHighlightRow: Int = -1
    @State var prevHighlightCol: Int = -1
    @State var showSettings: Bool = false
    @State var showPauseMenu: Bool = false
    @State var displayedScore: Int = 0
    @State var displayedHighScore: Int = 0
    @State var scoreAnimTimer: Timer? = nil
    @Environment(\.dismiss) var dismiss
    @Environment(BlockBlastSettings.self) var settings: BlockBlastSettings

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.13, blue: 0.25),
                    Color(red: 0.08, green: 0.08, blue: 0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                // Score header
                scoreHeader

                // Game board
                gameBoard

                // Piece tray
                pieceTray

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // Game over overlay
            if game.isGameOver {
                gameOverOverlay
            }

            // Pause menu overlay
            if showPauseMenu && !game.isGameOver {
                pauseMenuOverlay
            }

            // Combo popup
            if showCombo && game.lastLinesCleared > 0 {
                comboPopup
            }

        }
        .navigationBarBackButtonHidden()
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .sheet(isPresented: $showSettings) {
            BlockBlastSettingsView(settings: settings)
        }
        .onAppear {
            if let savedState = GameModel.loadSavedState() {
                game.restoreState(savedState)
                displayedScore = game.score
                displayedHighScore = game.highScore
            } else {
                displayedScore = game.score
                displayedHighScore = game.highScore
            }
            game.solvabilityAttempts = settings.solvabilityAttempts
        }
        .onDisappear {
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
        .onChange(of: settings.difficulty) { _, _ in
            game.solvabilityAttempts = settings.solvabilityAttempts
        }
    }

    // MARK: - Score Header

    var scoreHeader: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Image("close", bundle: .module)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("SCORE", bundle: .module)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.white.opacity(0.6))
                Text("\(displayedScore)")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.white)
                    .monospaced()
            }

            Spacer()

            Text("Block Blast", bundle: .module)
                .font(.title3)
                .fontWeight(.heavy)
                .foregroundStyle(Color.white)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("BEST", bundle: .module)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.white.opacity(0.6))
                Text("\(displayedHighScore)")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.yellow)
                    .monospaced()
            }

            Button(action: { showPauseMenu = true }) {
                Image("pause_circle", bundle: .module)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.1))
        )
    }

    // MARK: - Game Board

    var gameBoard: some View {
        GeometryReader { geo in
            let boardSize = min(geo.size.width, geo.size.height)
            let cs = boardSize / CGFloat(GameModel.gridSize)
            let originX = (geo.size.width - boardSize) / 2.0
            let originY: CGFloat = 0

            ZStack(alignment: .topLeading) {
                // Board background
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.15, green: 0.16, blue: 0.3))
                    .frame(width: boardSize, height: boardSize)
                    .offset(x: originX)

                // Grid cells
                ForEach(0..<GameModel.gridSize, id: \.self) { row in
                    ForEach(0..<GameModel.gridSize, id: \.self) { col in
                        let cellValue = game.grid[row][col]
                        let isHighlight = isDragging && isHighlightCell(row: row, col: col)

                        cellView(
                            colorIndex: cellValue,
                            isHighlight: isHighlight,
                            isValidHighlight: highlightValid,
                            size: cs
                        )
                        .offset(
                            x: originX + CGFloat(col) * cs,
                            y: originY + CGFloat(row) * cs
                        )
                    }
                }

                // Floating drag piece — rendered inside the board ZStack so it
                // shares the exact same coordinate space as the grid cells.
                if isDragging && dragPieceIndex >= 0 && dragPieceIndex < game.currentPieces.count {
                    if let piece = game.currentPieces[dragPieceIndex] {
                        floatingPiece(piece: piece, boardOriginX: originX, cs: cs)
                    }
                }
            }
            .onAppear {
                cellSize = cs
            }
            .onChange(of: geo.size) {
                let newBoardSize = min(geo.size.width, geo.size.height)
                cellSize = newBoardSize / CGFloat(GameModel.gridSize)
            }
            .background(
                // Track the board's global frame so boardOrigin stays
                // correct even after the navigation bar is hidden.
                // Re-read on appear, size change, and drag start to
                // catch position shifts from toolbar visibility changes.
                GeometryReader { boardGeo in
                    Color.clear
                        .onAppear { updateBoardOrigin(boardGeo) }
                        .onChange(of: boardGeo.size) { updateBoardOrigin(boardGeo) }
                        .onChange(of: isDragging) { updateBoardOrigin(boardGeo) }
                }
                .frame(width: boardSize, height: boardSize)
                .offset(x: originX)
            )
        }
        .aspectRatio(1.0, contentMode: .fit)
    }

    func updateBoardOrigin(_ geo: GeometryProxy) {
        let frame = geo.frame(in: .global)
        boardOrigin = CGPoint(x: frame.minX, y: frame.minY)
    }

    func isHighlightCell(row: Int, col: Int) -> Bool {
        if highlightRow < 0 || highlightCol < 0 { return false }
        if dragPieceIndex < 0 || dragPieceIndex >= game.currentPieces.count { return false }
        guard let piece = game.currentPieces[dragPieceIndex] else { return false }
        for cell in piece.shape.cells {
            if row == highlightRow + cell.row && col == highlightCol + cell.col {
                return true
            }
        }
        return false
    }

    func cellView(colorIndex: Int, isHighlight: Bool, isValidHighlight: Bool, size: CGFloat) -> some View {
        let inset: CGFloat = 1.5
        return ZStack {
            if isHighlight {
                RoundedRectangle(cornerRadius: 3)
                    .fill(isValidHighlight ? Color.white.opacity(0.4) : Color.red.opacity(0.3))
                    .frame(width: size - inset * 2, height: size - inset * 2)
            } else if colorIndex >= 0 {
                RoundedRectangle(cornerRadius: 3)
                    .fill(BlockColors.color(for: colorIndex))
                    .frame(width: size - inset * 2, height: size - inset * 2)
                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.3), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: size - inset * 2, height: size - inset * 2)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: size - inset * 2, height: size - inset * 2)
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - Piece Tray

    var pieceTray: some View {
        HStack(spacing: 16) {
            ForEach(0..<3, id: \.self) { index in
                pieceView(index: index)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.08))
        )
    }

    /// Fixed height for each piece slot — accommodates the tallest piece (5 cells)
    var pieceSlotHeight: CGFloat {
        let pieceScale: CGFloat = cellSize > 0.0 ? cellSize * 0.55 : 16.0
        return max(pieceScale * 5.0, 60.0)
    }

    func pieceView(index: Int) -> some View {
        let piece = game.currentPieces[index]
        let pieceScale: CGFloat = cellSize > 0.0 ? cellSize * 0.55 : 16.0
        let isBeingDragged = isDragging && dragPieceIndex == index
        let slotHeight = pieceSlotHeight

        return ZStack {
            if let piece = piece {
                let w = piece.shape.width
                let h = piece.shape.height
                let pieceWidth = CGFloat(w) * pieceScale
                let pieceHeight = CGFloat(h) * pieceScale

                ZStack(alignment: .topLeading) {
                    ForEach(0..<piece.shape.cells.count, id: \.self) { ci in
                        let cell = piece.shape.cells[ci]
                        RoundedRectangle(cornerRadius: 2)
                            .fill(BlockColors.color(for: piece.shape.colorIndex))
                            .frame(width: pieceScale - 2, height: pieceScale - 2)
                            .offset(
                                x: CGFloat(cell.col) * pieceScale + 1,
                                y: CGFloat(cell.row) * pieceScale + 1
                            )
                    }
                }
                .frame(width: pieceWidth, height: pieceHeight, alignment: .topLeading)
                .opacity(isBeingDragged ? 0.3 : 1.0)
            }
            // Invisible hit area that always maintains the fixed slot size
            Color.white.opacity(0.001)
        }
        .frame(maxWidth: .infinity)
        .frame(height: slotHeight)
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    if !showPauseMenu && game.currentPieces[index] != nil {
                        handleDragChanged(index: index, value: value)
                    }
                }
                .onEnded { value in
                    if !showPauseMenu && game.currentPieces[index] != nil {
                        handleDragEnded(index: index, value: value)
                    }
                }
        )
    }

    // MARK: - Floating Drag Piece

    func floatingPiece(piece: GamePiece, boardOriginX: CGFloat, cs: CGFloat) -> some View {
        let shape = piece.shape
        let pieceWidth = CGFloat(shape.width) * cs
        let pieceHeight = CGFloat(shape.height) * cs
        let fingerOffset: CGFloat = cs * 2.5

        // Use boardOrigin (global coords of the board) to convert the global
        // dragLocation into board-relative coordinates. This is the same math
        // used for the ghost highlight in handleDragChanged, ensuring they
        // always align perfectly on all platforms.
        //
        // Board-relative top-left of the piece:
        let boardRelX = dragLocation.x - boardOrigin.x - pieceWidth / 2.0
        let boardRelY = dragLocation.y - boardOrigin.y - fingerOffset - pieceHeight / 2.0

        // In the board's ZStack, grid cells are placed at (boardOriginX + col*cs, row*cs).
        // boardOrigin tracks the global position of the board background, which starts
        // at boardOriginX within the ZStack. So to place in ZStack coords:
        let offsetX = boardOriginX + boardRelX
        let offsetY = boardRelY

        return ZStack(alignment: .topLeading) {
            ForEach(0..<shape.cells.count, id: \.self) { ci in
                let cell = shape.cells[ci]
                let inset: CGFloat = 1.5
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(BlockColors.color(for: shape.colorIndex))
                        .frame(width: cs - inset * 2, height: cs - inset * 2)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.3), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: cs - inset * 2, height: cs - inset * 2)
                }
                .frame(width: cs, height: cs)
                .offset(
                    x: CGFloat(cell.col) * cs,
                    y: CGFloat(cell.row) * cs
                )
            }
        }
        .frame(width: pieceWidth, height: pieceHeight, alignment: .topLeading)
        .shadow(color: Color.black.opacity(0.5), radius: 8, y: 4)
        .offset(x: offsetX, y: offsetY)
        .allowsHitTesting(false)
    }

    // MARK: - Haptic Helper

    func playHaptic(_ pattern: HapticPattern) {
        if settings.vibrations {
            HapticFeedback.play(pattern)
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

    // MARK: - Drag Handling

    func handleDragChanged(index: Int, value: DragGesture.Value) {
        let wasAlreadyDragging = isDragging
        isDragging = true
        dragPieceIndex = index
        dragOffset = value.translation
        dragLocation = value.location

        if !wasAlreadyDragging {
            playHaptic(.pick)
        }

        // Calculate which grid cell the drag is over
        guard let piece = game.currentPieces[index] else { return }
        let shape = piece.shape

        // Offset the target point so the shape centers on the finger
        // with a vertical offset so the piece appears above the finger
        let fingerOffset: CGFloat = cellSize * 2.5
        let targetX = dragLocation.x - boardOrigin.x - CGFloat(shape.width) * cellSize / 2.0
        let targetY = dragLocation.y - boardOrigin.y - fingerOffset - CGFloat(shape.height) * cellSize / 2.0

        let col = Int(round(targetX / cellSize))
        let row = Int(round(targetY / cellSize))

        // Fire snap haptic when moving to a new valid grid cell
        if row != prevHighlightRow || col != prevHighlightCol {
            let isValid = game.canPlace(shape: shape, atRow: row, col: col)
            if isValid {
                playHaptic(.snap)
            }
            prevHighlightRow = row
            prevHighlightCol = col
        }

        highlightRow = row
        highlightCol = col
        highlightValid = game.canPlace(shape: shape, atRow: row, col: col)
    }

    func handleDragEnded(index: Int, value: DragGesture.Value) {
        if highlightValid && highlightRow >= 0 && highlightCol >= 0 {
            if let piece = game.currentPieces[index] {
                game.placeShape(shape: piece.shape, atRow: highlightRow, col: highlightCol, pieceIndex: index)

                if game.comboStreak > 2 {
                    playHaptic(.combo(streak: game.comboStreak))
                } else if game.lastLinesCleared > 1 {
                    playHaptic(.bigCelebrate)
                } else if game.lastLinesCleared > 0 {
                    playHaptic(.celebrate)
                } else {
                    playHaptic(.place)
                }

                if game.lastLinesCleared > 0 {
                    showCombo = true
                    let popupDuration = game.boardCleared ? 2.0 : 1.0
                    DispatchQueue.main.asyncAfter(deadline: .now() + popupDuration) {
                        showCombo = false
                    }
                }

                if game.isGameOver {
                    playHaptic(.error)
                }

                game.saveState()
            }
        } else if isDragging {
            playHaptic(.warning)
        }

        isDragging = false
        dragPieceIndex = -1
        dragOffset = CGSize.zero
        highlightRow = -1
        highlightCol = -1
        highlightValid = false
        prevHighlightRow = -1
        prevHighlightCol = -1
    }

    // MARK: - Pause Menu Overlay

    var pauseMenuOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

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
                    GameModel.clearSavedState()
                    game.newGame()
                    stopScoreAnimation()
                    displayedScore = 0
                    displayedHighScore = game.highScore
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
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.18))
            )
        }
    }

    // MARK: - Game Over Overlay

    var gameOverOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Text("Game Over", bundle: .module)
                    .font(.largeTitle)
                    .fontWeight(.heavy)
                    .foregroundStyle(Color.white)

                VStack(spacing: 8) {
                    Text("Score", bundle: .module)
                        .font(.headline)
                        .foregroundStyle(Color.white.opacity(0.7))
                    Text("\(displayedScore)")
                        .font(.system(size: 48))
                        .fontWeight(.bold)
                        .foregroundStyle(Color.yellow)
                        .monospaced()
                }

                VStack(spacing: 2) {
                    Text("Difficulty", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                    Text("\(settings.difficulty)")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                }

                if game.score >= game.highScore && game.score > 0 {
                    Text("New High Score!", bundle: .module)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.yellow)
                }

                Button(action: {
                    GameModel.clearSavedState()
                    game.newGame()
                    stopScoreAnimation()
                    displayedScore = 0
                    displayedHighScore = game.highScore
                }) {
                    Text("Play Again", bundle: .module)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .padding(.top, 8)

                Button(action: {
                    dismiss()
                }) {
                    Text("Quit Game", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                ShareLink(
                    item: "I scored \(game.score) in Block Blast (difficulty \(settings.difficulty)) on Faire Games! Can you beat it?\nhttps://appfair.net",
                    subject: Text("Block Blast Score", bundle: .module),
                    message: Text("I scored \(game.score) in Block Blast!")
                ) {
                    Label { Text("Share", bundle: .module) } icon: { Image(systemName: "square.and.arrow.up") }
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(red: 0.15, green: 0.16, blue: 0.3))
            )
        }
    }

    // MARK: - Combo Popup

    var comboPopup: some View {
        VStack(spacing: 4) {
            if game.boardCleared {
                Text("Board Clear! +\(boardClearBonus)")
                    .font(.title)
                    .fontWeight(.heavy)
                    .foregroundStyle(Color.green)
            }
            if game.lastLinesCleared > 1 {
                Text("\(game.lastLinesCleared)x Lines!")
                    .font(.title)
                    .fontWeight(.heavy)
                    .foregroundStyle(Color.yellow)
            }
            if game.comboStreak > 1 {
                Text("Combo x\(game.comboStreak)!")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.orange)
            } else if game.lastLinesCleared == 1 {
                Text("Line Clear!", bundle: .module)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.cyan)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.7))
        )
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

// MARK: - Color Palette

/// Block colors used throughout the game
struct BlockColors {
    static func color(for index: Int) -> Color {
        switch index {
        case 0: return Color.red
        case 1: return Color.blue
        case 2: return Color.green
        case 3: return Color.orange
        case 4: return Color.purple
        case 5: return Color.yellow
        case 6: return Color.pink
        default: return Color.gray
        }
    }

    static func darkColor(for index: Int) -> Color {
        switch index {
        case 0: return Color(red: 0.7, green: 0.1, blue: 0.1)
        case 1: return Color(red: 0.1, green: 0.2, blue: 0.7)
        case 2: return Color(red: 0.1, green: 0.5, blue: 0.1)
        case 3: return Color(red: 0.8, green: 0.4, blue: 0.0)
        case 4: return Color(red: 0.5, green: 0.1, blue: 0.5)
        case 5: return Color(red: 0.7, green: 0.6, blue: 0.0)
        case 6: return Color(red: 0.8, green: 0.3, blue: 0.5)
        default: return Color.gray
        }
    }
}

// MARK: - Block Shape Definitions

/// Represents a single cell offset within a block shape
struct CellOffset: Hashable, Sendable {
    let row: Int
    let col: Int
}

/// All available block shapes in the game (no rotation)
final class BlockShape: Identifiable, Hashable, Sendable {
    let id: String
    let cells: [CellOffset]
    let colorIndex: Int

    init(id: String, cells: [CellOffset], colorIndex: Int) {
        self.id = id
        self.cells = cells
        self.colorIndex = colorIndex
    }

    static func == (lhs: BlockShape, rhs: BlockShape) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var width: Int {
        var maxCol = 0
        for c in cells {
            if c.col > maxCol { maxCol = c.col }
        }
        return maxCol + 1
    }

    var height: Int {
        var maxRow = 0
        for c in cells {
            if c.row > maxRow { maxRow = c.row }
        }
        return maxRow + 1
    }
}

/// All the shapes available in the game
struct ShapeLibrary {
    static let allShapes: [BlockShape] = [
        // Single dot
        BlockShape(id: "dot", cells: [CellOffset(row: 0, col: 0)], colorIndex: 0),

        // 1x2 horizontal
        BlockShape(id: "h2", cells: [
            CellOffset(row: 0, col: 0), CellOffset(row: 0, col: 1)
        ], colorIndex: 1),

        // 1x3 horizontal
        BlockShape(id: "h3", cells: [
            CellOffset(row: 0, col: 0), CellOffset(row: 0, col: 1), CellOffset(row: 0, col: 2)
        ], colorIndex: 2),

        // 1x4 horizontal
        BlockShape(id: "h4", cells: [
            CellOffset(row: 0, col: 0), CellOffset(row: 0, col: 1),
            CellOffset(row: 0, col: 2), CellOffset(row: 0, col: 3)
        ], colorIndex: 3),

        // 1x5 horizontal
        BlockShape(id: "h5", cells: [
            CellOffset(row: 0, col: 0), CellOffset(row: 0, col: 1),
            CellOffset(row: 0, col: 2), CellOffset(row: 0, col: 3),
            CellOffset(row: 0, col: 4)
        ], colorIndex: 4),

        // 2x1 vertical
        BlockShape(id: "v2", cells: [
            CellOffset(row: 0, col: 0), CellOffset(row: 1, col: 0)
        ], colorIndex: 1),

        // 3x1 vertical
        BlockShape(id: "v3", cells: [
            CellOffset(row: 0, col: 0), CellOffset(row: 1, col: 0), CellOffset(row: 2, col: 0)
        ], colorIndex: 2),

        // 4x1 vertical
        BlockShape(id: "v4", cells: [
            CellOffset(row: 0, col: 0), CellOffset(row: 1, col: 0),
            CellOffset(row: 2, col: 0), CellOffset(row: 3, col: 0)
        ], colorIndex: 3),

        // 5x1 vertical
        BlockShape(id: "v5", cells: [
            CellOffset(row: 0, col: 0), CellOffset(row: 1, col: 0),
            CellOffset(row: 2, col: 0), CellOffset(row: 3, col: 0),
            CellOffset(row: 4, col: 0)
        ], colorIndex: 4),

        // 2x2 square
        BlockShape(id: "sq2", cells: [
            CellOffset(row: 0, col: 0), CellOffset(row: 0, col: 1),
            CellOffset(row: 1, col: 0), CellOffset(row: 1, col: 1)
        ], colorIndex: 5),

        // 3x3 square
        BlockShape(id: "sq3", cells: [
            CellOffset(row: 0, col: 0), CellOffset(row: 0, col: 1), CellOffset(row: 0, col: 2),
            CellOffset(row: 1, col: 0), CellOffset(row: 1, col: 1), CellOffset(row: 1, col: 2),
            CellOffset(row: 2, col: 0), CellOffset(row: 2, col: 1), CellOffset(row: 2, col: 2)
        ], colorIndex: 6),

        // L-shape (bottom-left)
        BlockShape(id: "L_bl", cells: [
            CellOffset(row: 0, col: 0),
            CellOffset(row: 1, col: 0), CellOffset(row: 1, col: 1)
        ], colorIndex: 0),

        // L-shape (bottom-right)
        BlockShape(id: "L_br", cells: [
            CellOffset(row: 0, col: 1),
            CellOffset(row: 1, col: 0), CellOffset(row: 1, col: 1)
        ], colorIndex: 1),

        // L-shape (top-left)
        BlockShape(id: "L_tl", cells: [
            CellOffset(row: 0, col: 0), CellOffset(row: 0, col: 1),
            CellOffset(row: 1, col: 0)
        ], colorIndex: 2),

        // L-shape (top-right)
        BlockShape(id: "L_tr", cells: [
            CellOffset(row: 0, col: 0), CellOffset(row: 0, col: 1),
            CellOffset(row: 1, col: 1)
        ], colorIndex: 3),

        // 2x3 L (bottom-left corner) — 2 wide, 3 tall
        BlockShape(id: "L23_bl", cells: [
            CellOffset(row: 0, col: 0),
            CellOffset(row: 1, col: 0),
            CellOffset(row: 2, col: 0), CellOffset(row: 2, col: 1)
        ], colorIndex: 4),

        // 2x3 L (bottom-right corner) — 2 wide, 3 tall
        BlockShape(id: "L23_br", cells: [
            CellOffset(row: 0, col: 1),
            CellOffset(row: 1, col: 1),
            CellOffset(row: 2, col: 0), CellOffset(row: 2, col: 1)
        ], colorIndex: 5),

        // 2x3 L (top-left corner) — 2 wide, 3 tall
        BlockShape(id: "L23_tl", cells: [
            CellOffset(row: 0, col: 0), CellOffset(row: 0, col: 1),
            CellOffset(row: 1, col: 0),
            CellOffset(row: 2, col: 0)
        ], colorIndex: 6),

        // 2x3 L (top-right corner) — 2 wide, 3 tall
        BlockShape(id: "L23_tr", cells: [
            CellOffset(row: 0, col: 0), CellOffset(row: 0, col: 1),
            CellOffset(row: 1, col: 1),
            CellOffset(row: 2, col: 1)
        ], colorIndex: 0),

        // Filled 2x3 rectangle — 2 wide, 3 tall
        BlockShape(id: "rect2x3", cells: [
            CellOffset(row: 0, col: 0), CellOffset(row: 0, col: 1),
            CellOffset(row: 1, col: 0), CellOffset(row: 1, col: 1),
            CellOffset(row: 2, col: 0), CellOffset(row: 2, col: 1)
        ], colorIndex: 1),

        // Filled 3x2 rectangle — 3 wide, 2 tall
        BlockShape(id: "rect3x2", cells: [
            CellOffset(row: 0, col: 0), CellOffset(row: 0, col: 1), CellOffset(row: 0, col: 2),
            CellOffset(row: 1, col: 0), CellOffset(row: 1, col: 1), CellOffset(row: 1, col: 2)
        ], colorIndex: 2),

        // T-shape (pointing up)
        BlockShape(id: "T_up", cells: [
            CellOffset(row: 0, col: 0), CellOffset(row: 0, col: 1), CellOffset(row: 0, col: 2),
            CellOffset(row: 1, col: 1)
        ], colorIndex: 1),

        // T-shape (pointing down)
        BlockShape(id: "T_dn", cells: [
            CellOffset(row: 0, col: 1),
            CellOffset(row: 1, col: 0), CellOffset(row: 1, col: 1), CellOffset(row: 1, col: 2)
        ], colorIndex: 2),

        // T-shape (pointing left)
        BlockShape(id: "T_lt", cells: [
            CellOffset(row: 0, col: 0),
            CellOffset(row: 1, col: 0), CellOffset(row: 1, col: 1),
            CellOffset(row: 2, col: 0)
        ], colorIndex: 3),

        // T-shape (pointing right)
        BlockShape(id: "T_rt", cells: [
            CellOffset(row: 0, col: 1),
            CellOffset(row: 1, col: 0), CellOffset(row: 1, col: 1),
            CellOffset(row: 2, col: 1)
        ], colorIndex: 4),

        // S-shape horizontal
        BlockShape(id: "S_h", cells: [
            CellOffset(row: 0, col: 1), CellOffset(row: 0, col: 2),
            CellOffset(row: 1, col: 0), CellOffset(row: 1, col: 1)
        ], colorIndex: 5),

        // Z-shape horizontal
        BlockShape(id: "Z_h", cells: [
            CellOffset(row: 0, col: 0), CellOffset(row: 0, col: 1),
            CellOffset(row: 1, col: 1), CellOffset(row: 1, col: 2)
        ], colorIndex: 6),

        // S-shape vertical
        BlockShape(id: "S_v", cells: [
            CellOffset(row: 0, col: 0),
            CellOffset(row: 1, col: 0), CellOffset(row: 1, col: 1),
            CellOffset(row: 2, col: 1)
        ], colorIndex: 5),

        // Z-shape vertical
        BlockShape(id: "Z_v", cells: [
            CellOffset(row: 0, col: 1),
            CellOffset(row: 1, col: 0), CellOffset(row: 1, col: 1),
            CellOffset(row: 2, col: 0)
        ], colorIndex: 6),
    ]

    static func randomShape() -> BlockShape {
        let index = Int.random(in: 0..<allShapes.count)
        return allShapes[index]
    }

    static func randomSet() -> [BlockShape] {
        return [randomShape(), randomShape(), randomShape()]
    }
}

// MARK: - Saved State

struct BlockBlastSavedState: Codable {
    var grid: [[Int]]
    var pieceShapeIds: [String]
    var score: Int
    var highScore: Int
    var isGameOver: Bool
    var comboStreak: Int
    var boardCleared: Bool
}

// MARK: - Game Model

/// A piece the player can place, with a unique identity for tracking
final class GamePiece: Identifiable, Hashable {
    let id: String
    let shape: BlockShape

    init(shape: BlockShape) {
        self.id = UUID().uuidString
        self.shape = shape
    }

    static func == (lhs: GamePiece, rhs: GamePiece) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// The main game model
@Observable final class GameModel {
    static let gridSize = 8

    /// The 8x8 grid. Each cell is -1 if empty, or a colorIndex (0-6) if filled.
    var grid: [[Int]] = Array(repeating: Array(repeating: -1, count: 8), count: 8)

    /// The current set of three pieces available to place
    var currentPieces: [GamePiece?] = [nil, nil, nil]

    /// Current score
    var score: Int = 0

    /// High score
    var highScore: Int = 0

    /// Whether the game is over
    var isGameOver: Bool = false

    /// Number of lines cleared in last move (for combo display)
    var lastLinesCleared: Int = 0

    /// Combo streak counter
    var comboStreak: Int = 0

    /// Whether the board was completely cleared on the last move
    var boardCleared: Bool = false

    /// Set of cells to animate as clearing
    var clearingCells: Set<Int> = []

    /// Number of attempts to make when generating a solvable piece set.
    /// 0 means no validation (purely random), higher values try harder to
    /// find a solvable set. Set by the view from the player's difficulty preference.
    var solvabilityAttempts: Int = 20

    init() {
        loadHighScore()
        spawnNewPieces()
    }

    // MARK: - Core Game Logic

    func newGame() {
        grid = Array(repeating: Array(repeating: -1, count: 8), count: 8)
        score = 0
        isGameOver = false
        lastLinesCleared = 0
        comboStreak = 0
        boardCleared = false
        clearingCells = []
        spawnNewPieces()
    }

    func spawnNewPieces() {
        // Try up to `solvabilityAttempts` random sets to find a solvable one.
        // When attempts is 0 (max difficulty), we skip directly to a pure random pick.
        for _ in 0..<solvabilityAttempts {
            let shapes = ShapeLibrary.randomSet()
            if isSolvableSet(shapes: shapes) {
                currentPieces = [
                    GamePiece(shape: shapes[0]),
                    GamePiece(shape: shapes[1]),
                    GamePiece(shape: shapes[2])
                ]
                return
            }
        }
        // Fallback (or pure-random when attempts == 0): use whatever we got
        let shapes = ShapeLibrary.randomSet()
        currentPieces = [
            GamePiece(shape: shapes[0]),
            GamePiece(shape: shapes[1]),
            GamePiece(shape: shapes[2])
        ]
    }

    /// Check if there exists at least one ordering of the 3 shapes where
    /// all can be placed sequentially on the current board.
    /// For each permutation, greedily places each shape at the first valid
    /// position found, applying line clears between placements.
    private func isSolvableSet(shapes: [BlockShape]) -> Bool {
        let gs = GameModel.gridSize
        // Try all 6 permutations of 3 shapes
        let perms = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        for perm in perms {
            // Copy the grid for simulation
            var simGrid: [[Int]] = []
            for r in 0..<gs {
                simGrid.append(grid[r])
            }
            var allPlaced = true
            for idx in perm {
                let shape = shapes[idx]
                let placed = simulatePlace(shape: shape, grid: &simGrid)
                if !placed {
                    allPlaced = false
                    break
                }
                simulateClearLines(grid: &simGrid)
            }
            if allPlaced {
                return true
            }
        }
        return false
    }

    /// Try to place a shape anywhere on the simulated grid. Returns true if placed.
    private func simulatePlace(shape: BlockShape, grid: inout [[Int]]) -> Bool {
        let gs = GameModel.gridSize
        for r in 0..<gs {
            for c in 0..<gs {
                var fits = true
                for cell in shape.cells {
                    let cr = r + cell.row
                    let cc = c + cell.col
                    if cr < 0 || cr >= gs || cc < 0 || cc >= gs || grid[cr][cc] != -1 {
                        fits = false
                        break
                    }
                }
                if fits {
                    for cell in shape.cells {
                        grid[r + cell.row][c + cell.col] = shape.colorIndex
                    }
                    return true
                }
            }
        }
        return false
    }

    /// Clear any completed rows/columns in the simulated grid.
    private func simulateClearLines(grid: inout [[Int]]) {
        let gs = GameModel.gridSize
        // Find full rows
        for r in 0..<gs {
            var full = true
            for c in 0..<gs {
                if grid[r][c] == -1 { full = false; break }
            }
            if full {
                for c in 0..<gs { grid[r][c] = -1 }
            }
        }
        // Find full columns
        for c in 0..<gs {
            var full = true
            for r in 0..<gs {
                if grid[r][c] == -1 { full = false; break }
            }
            if full {
                for r in 0..<gs { grid[r][c] = -1 }
            }
        }
    }

    /// Check if a shape can be placed at the given grid position
    func canPlace(shape: BlockShape, atRow row: Int, col: Int) -> Bool {
        for cell in shape.cells {
            let r = row + cell.row
            let c = col + cell.col
            if r < 0 || r >= GameModel.gridSize || c < 0 || c >= GameModel.gridSize {
                return false
            }
            if grid[r][c] != -1 {
                return false
            }
        }
        return true
    }

    /// Check if every cell on the board is empty
    func isBoardEmpty() -> Bool {
        for r in 0..<GameModel.gridSize {
            for c in 0..<GameModel.gridSize {
                if grid[r][c] != -1 { return false }
            }
        }
        return true
    }

    /// Place a shape on the grid and handle scoring/clearing
    func placeShape(shape: BlockShape, atRow row: Int, col: Int, pieceIndex: Int) {
        boardCleared = false

        // Place the cells
        for cell in shape.cells {
            let r = row + cell.row
            let c = col + cell.col
            grid[r][c] = shape.colorIndex
        }

        // Add points for placing (1 point per cell)
        score += shape.cells.count

        // Remove the placed piece
        currentPieces[pieceIndex] = nil

        // Check and clear completed lines
        let linesCleared = clearCompletedLines()
        lastLinesCleared = linesCleared

        if linesCleared > 0 {
            comboStreak += 1
            // Scoring: 10 points per line, bonus for combos and multi-line clears
            let linePoints = linesCleared * 10
            let comboBonus = comboStreak > 1 ? comboStreak * 5 : 0
            let multiLineBonus = linesCleared > 1 ? linesCleared * 5 : 0
            score += linePoints + comboBonus + multiLineBonus

            // Board clear bonus
            if isBoardEmpty() {
                boardCleared = true
                score += boardClearBonus
            }
        } else {
            comboStreak = 0
        }

        // Check if all three pieces are placed
        let allPlaced = currentPieces[0] == nil && currentPieces[1] == nil && currentPieces[2] == nil
        if allPlaced {
            spawnNewPieces()
        }

        // Check for game over
        if checkGameOver() {
            isGameOver = true
            if score > highScore {
                highScore = score
                saveHighScore()
            }
        }
    }

    /// Clear any completed rows and columns, returns count cleared
    func clearCompletedLines() -> Int {
        var rowsToClear: [Int] = []
        var colsToClear: [Int] = []

        // Check rows
        for r in 0..<GameModel.gridSize {
            var full = true
            for c in 0..<GameModel.gridSize {
                if grid[r][c] == -1 {
                    full = false
                    break
                }
            }
            if full {
                rowsToClear.append(r)
            }
        }

        // Check columns
        for c in 0..<GameModel.gridSize {
            var full = true
            for r in 0..<GameModel.gridSize {
                if grid[r][c] == -1 {
                    full = false
                    break
                }
            }
            if full {
                colsToClear.append(c)
            }
        }

        // Build set of cells to clear for animation
        var cellsToClear = Set<Int>()
        for r in rowsToClear {
            for c in 0..<GameModel.gridSize {
                cellsToClear.insert(r * GameModel.gridSize + c)
            }
        }
        for c in colsToClear {
            for r in 0..<GameModel.gridSize {
                cellsToClear.insert(r * GameModel.gridSize + c)
            }
        }
        clearingCells = cellsToClear

        // Clear the rows
        for r in rowsToClear {
            for c in 0..<GameModel.gridSize {
                grid[r][c] = -1
            }
        }

        // Clear the columns
        for c in colsToClear {
            for r in 0..<GameModel.gridSize {
                grid[r][c] = -1
            }
        }

        return rowsToClear.count + colsToClear.count
    }

    /// Check if any remaining piece can be placed anywhere
    func checkGameOver() -> Bool {
        for piece in currentPieces {
            guard let piece = piece else { continue }
            for r in 0..<GameModel.gridSize {
                for c in 0..<GameModel.gridSize {
                    if canPlace(shape: piece.shape, atRow: r, col: c) {
                        return false
                    }
                }
            }
        }
        return true
    }

    /// Check if a specific piece can be placed anywhere on the board
    func canPieceFit(piece: GamePiece) -> Bool {
        for r in 0..<GameModel.gridSize {
            for c in 0..<GameModel.gridSize {
                if canPlace(shape: piece.shape, atRow: r, col: c) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Persistence

    private func saveHighScore() {
        UserDefaults.standard.set(highScore, forKey: "blockblast_highscore")
    }

    private func loadHighScore() {
        highScore = UserDefaults.standard.integer(forKey: "blockblast_highscore")
    }

    /// Resets the persisted high score to zero.
    static func resetHighScore() {
        UserDefaults.standard.set(0, forKey: "blockblast_highscore")
    }

    // MARK: - Game State Persistence

    func makeSavedState() -> BlockBlastSavedState {
        var pieceShapeIds: [String] = []
        for piece in currentPieces {
            if let piece = piece {
                pieceShapeIds.append(piece.shape.id)
            } else {
                pieceShapeIds.append("")
            }
        }
        return BlockBlastSavedState(
            grid: grid,
            pieceShapeIds: pieceShapeIds,
            score: score,
            highScore: highScore,
            isGameOver: isGameOver,
            comboStreak: comboStreak,
            boardCleared: boardCleared
        )
    }

    func restoreState(_ state: BlockBlastSavedState) {
        grid = state.grid
        score = state.score
        highScore = state.highScore
        isGameOver = state.isGameOver
        comboStreak = state.comboStreak
        boardCleared = state.boardCleared

        var restoredPieces: [GamePiece?] = []
        for shapeId in state.pieceShapeIds {
            if shapeId == "" {
                restoredPieces.append(nil)
            } else {
                var foundShape: BlockShape? = nil
                for shape in ShapeLibrary.allShapes {
                    if shape.id == shapeId {
                        foundShape = shape
                        break
                    }
                }
                if let shape = foundShape {
                    restoredPieces.append(GamePiece(shape: shape))
                } else {
                    restoredPieces.append(nil)
                }
            }
        }
        currentPieces = restoredPieces
    }

    func saveState() {
        guard let data = try? JSONEncoder().encode(makeSavedState()) else { return }
        guard let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: "blockblast_saved_state")
    }

    static func loadSavedState() -> BlockBlastSavedState? {
        guard let json = UserDefaults.standard.string(forKey: "blockblast_saved_state") else { return nil }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BlockBlastSavedState.self, from: data)
    }

    static func clearSavedState() {
        UserDefaults.standard.removeObject(forKey: "blockblast_saved_state")
    }
}

// MARK: - Public High Score Reset

/// Resets the Block Blast high score to zero.
public func resetBlockBlastHighScore() {
    GameModel.resetHighScore()
}

// MARK: - Preview Icon

/// Returns the color index for a Block Blast preview icon cell, or -1 if empty.
private func blockBlastPreviewColorIndex(row: Int, col: Int) -> Int {
    // Bottom two rows filled
    if row == 3 { return 0 } // red
    if row == 4 { return 1 } // blue
    // Left column stack
    if col == 0 && row >= 0 && row <= 2 { return 2 } // green
    // Small orange block
    if row == 2 && (col == 1 || col == 2) { return 3 } // orange
    // Purple square
    if (row == 1 || row == 2) && (col == 3 || col == 4) { return 4 } // purple
    return -1
}

/// A preview icon for the Block Blast game, using the same 3D cell rendering as the game.
public struct BlockBlastPreviewIcon: View {
    public init() { }

    public var body: some View {
        GeometryReader { geo in
            let gridSize = 5
            let spacing: CGFloat = 1
            let totalSpacing = spacing * CGFloat(gridSize - 1)
            let padding: CGFloat = 4
            let available = min(geo.size.width, geo.size.height) - padding * 2
            let cellSize = (available - totalSpacing) / CGFloat(gridSize)

            VStack(spacing: spacing) {
                ForEach(0..<gridSize, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<gridSize, id: \.self) { col in
                            let colorIndex = blockBlastPreviewColorIndex(row: row, col: col)
                            ZStack {
                                if colorIndex >= 0 {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(BlockColors.color(for: colorIndex))
                                        .frame(width: cellSize, height: cellSize)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(
                                            LinearGradient(
                                                colors: [Color.white.opacity(0.3), Color.clear],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: cellSize, height: cellSize)
                                } else {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.white.opacity(0.05))
                                        .frame(width: cellSize, height: cellSize)
                                }
                            }
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
                .fill(Color(red: 0.12, green: 0.12, blue: 0.22))
        )
    }
}

// MARK: - In-Game Settings Sheet

struct BlockBlastSettingsView: View {
    @Bindable var settings: BlockBlastSettings
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Block Blast", bundle: .module)) {
                    Toggle(isOn: $settings.vibrations) { Text("Vibrations", bundle: .module) }
                }
                Section(header: Text("Difficulty", bundle: .module)) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Level", bundle: .module)
                            Spacer()
                            Text("\(settings.difficulty)")
                                .foregroundStyle(Color.secondary)
                                .monospaced()
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.difficulty) },
                                set: { settings.difficulty = Int($0.rounded()) }
                            ),
                            in: 0.0...10.0,
                            step: 1.0
                        )
                        HStack {
                            Text("Easy", bundle: .module)
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                            Spacer()
                            Text("Hard", bundle: .module)
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
                Section {
                    Text("At difficulty 0, the game tries 20 times to offer a solvable set of blocks. At difficulty 10, blocks are picked purely at random and the game may become unwinnable.", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
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

/// Settings specific to the Block Blast game.
@Observable
public class BlockBlastSettings {
    /// Whether vibrations (haptic feedback) are enabled for Block Blast.
    public var vibrations: Bool = defaults.value(forKey: "blockBlastVibrations", default: true) {
        didSet { defaults.set(vibrations, forKey: "blockBlastVibrations") }
    }

    /// Difficulty level from 0 (easiest — always solvable) to 10 (hardest — pure
    /// random). The number of solvability attempts when generating a piece set
    /// is `20 - 2 * difficulty`, so 0 → 20 attempts, 5 → 10 attempts, 10 → 0.
    public var difficulty: Int = defaults.value(forKey: "blockBlastDifficulty", default: 0) {
        didSet { defaults.set(difficulty, forKey: "blockBlastDifficulty") }
    }

    /// The number of solvability attempts implied by the current difficulty.
    public var solvabilityAttempts: Int {
        return max(0, 20 - difficulty * 2)
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
