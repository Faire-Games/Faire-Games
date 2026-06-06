// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import Observation
import SkipKit
import SkipModel
import FaireGamesModel

/// Big chunky bonus awarded when the player clears the entire 8×8 board.
/// The score is intentionally large so a perfect clear feels like a payoff.
private let boardClearBonus: Int = 5000

/// Per-cell placement points. Bigger than 1 because four-digit gains feel more
/// rewarding than single-digit ones — placement of a 5-cell piece nets 50.
private let placementPointsPerCell: Int = 10

/// Base per-line points before the multi-line and combo bonuses are applied.
private let basePointsPerLine: Int = 100

/// How long the encouraging-message popup lingers before fading.
private let messageHoldDuration: Double = 1.1
/// How long the board-clear "perfect" popup lingers.
private let perfectMessageHoldDuration: Double = 1.9
/// Confetti pool size used during board-clear celebrations.
private let confettiCount: Int = 80

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
    @State var showDifficultyPicker: Bool = false
    /// Guards the initial `onAppear` so the difficulty picker (or saved-state
    /// restore) fires exactly once per view lifetime, even if SwiftUI reruns
    /// `onAppear` after sheet dismissals or focus changes.
    @State var hasInitialized: Bool = false
    @State var displayedScore: Int = 0
    @State var displayedHighScore: Int = 0
    @State var scoreAnimTimer: Timer? = nil

    // MARK: - Animation state (per-cell parallel arrays, indexed by row * gridSize + col)

    /// Color of the ghost cell to render in the burst layer (-1 = none).
    @State var ghostColor: [Int] = Array(repeating: -1, count: GameModel.gridSize * GameModel.gridSize)
    /// Scale of the ghost cell as it fades out.
    @State var ghostScale: [CGFloat] = Array(repeating: 1.0, count: GameModel.gridSize * GameModel.gridSize)
    /// Opacity of the ghost cell as it fades out.
    @State var ghostOpacity: [CGFloat] = Array(repeating: 0.0, count: GameModel.gridSize * GameModel.gridSize)
    /// Rotation of the ghost cell as it tumbles outward.
    @State var ghostRotation: [CGFloat] = Array(repeating: 0.0, count: GameModel.gridSize * GameModel.gridSize)
    /// Color used for the burst ring at this cell.
    @State var burstColor: [Int] = Array(repeating: 0, count: GameModel.gridSize * GameModel.gridSize)
    /// Scale of the expanding burst ring.
    @State var burstScale: [CGFloat] = Array(repeating: 0.0, count: GameModel.gridSize * GameModel.gridSize)
    /// Opacity of the burst ring.
    @State var burstOpacity: [CGFloat] = Array(repeating: 0.0, count: GameModel.gridSize * GameModel.gridSize)
    /// White flash overlay opacity, used to telegraph a line clear.
    @State var flashOpacity: [CGFloat] = Array(repeating: 0.0, count: GameModel.gridSize * GameModel.gridSize)
    /// Squash-pulse scale for cells that were just placed.
    @State var placedScale: [CGFloat] = Array(repeating: 1.0, count: GameModel.gridSize * GameModel.gridSize)

    /// Camera shake offsets.
    @State var shakeOffsetX: CGFloat = 0.0
    @State var shakeOffsetY: CGFloat = 0.0

    /// Encouraging message popup state.
    /// `messageIndex` selects a phrase within the tier (see `EncouragingMessages`).
    @State var messageTier: Int = 0
    @State var messageIndex: Int = 0
    @State var messageScale: CGFloat = 0.0
    @State var messageOpacity: CGFloat = 0.0
    @State var messageRotation: CGFloat = 0.0

    /// Floating "+points" score-gain popup state.
    @State var scoreGain: Int = 0
    @State var scoreGainOffset: CGFloat = 0.0
    @State var scoreGainOpacity: CGFloat = 0.0
    @State var scoreGainScale: CGFloat = 0.0

    /// Combo badge pulse value (0 = idle, 1 = peak).
    @State var comboPulse: CGFloat = 0.0
    /// Whole-board gentle pulse used on every successful clear.
    @State var boardPulse: CGFloat = 0.0

    /// Confetti pool used on a perfect board clear. Parallel arrays.
    @State var confettiX: [CGFloat] = Array(repeating: 0.0, count: confettiCount)
    @State var confettiY: [CGFloat] = Array(repeating: -100.0, count: confettiCount)
    @State var confettiVX: [CGFloat] = Array(repeating: 0.0, count: confettiCount)
    @State var confettiVY: [CGFloat] = Array(repeating: 0.0, count: confettiCount)
    @State var confettiRotation: [CGFloat] = Array(repeating: 0.0, count: confettiCount)
    @State var confettiRotationSpeed: [CGFloat] = Array(repeating: 0.0, count: confettiCount)
    @State var confettiColor: [Int] = Array(repeating: 0, count: confettiCount)
    @State var confettiOpacity: [CGFloat] = Array(repeating: 0.0, count: confettiCount)
    @State var confettiActive: Bool = false
    @State var confettiTimer: Timer? = nil

    /// Pending animation timers — invalidated on disappear / new game.
    @State var animTimers: [Timer] = []
    @Environment(\.dismiss) var dismiss
    @Environment(BlockBlastSettings.self) var settings: BlockBlastSettings

    /// Returns whether the message popup should be visible.
    var hasActivePopup: Bool {
        return messageOpacity > 0.0 || scoreGainOpacity > 0.0
    }

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
                    .offset(x: shakeOffsetX, y: shakeOffsetY)
                    .scaleEffect(1.0 + boardPulse * 0.025)

                // Piece tray
                pieceTray

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // Confetti overlay (full screen)
            if confettiActive {
                confettiOverlay
            }

            // Encouraging message + score gain popup
            if messageOpacity > 0.0 || scoreGainOpacity > 0.0 {
                messagePopup
            }

            // Game over overlay
            if game.isGameOver {
                gameOverOverlay
            }

            // Pause menu overlay
            if showPauseMenu && !game.isGameOver {
                pauseMenuOverlay
            }

        }
        .navigationBarBackButtonHidden()
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .sheet(isPresented: $showSettings) {
            BlockBlastSettingsView(settings: settings)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showDifficultyPicker) {
            BlockBlastDifficultyPickerView(currentDifficulty: game.difficulty) { picked in
                GameModel.clearSavedState()
                cancelAllAnimTimers()
                resetAllAnimationState()
                game.newGame(difficulty: picked)
                stopScoreAnimation()
                displayedScore = 0
                displayedHighScore = game.highScore
                showDifficultyPicker = false
                showPauseMenu = false
                playHaptic(.snap)
            }
        }
        .onAppear {
            if !hasInitialized {
                hasInitialized = true
                if let savedState = GameModel.loadSavedState() {
                    game.restoreState(savedState)
                    displayedScore = game.score
                    displayedHighScore = game.highScore
                } else {
                    // No saved state — prompt for difficulty before starting.
                    displayedScore = game.score
                    displayedHighScore = game.highScore
                    showDifficultyPicker = true
                }
            }
        }
        .onDisappear {
            stopScoreAnimation()
            cancelAllAnimTimers()
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
            .accessibilityIdentifier("button.close")
            .accessibilityLabel(Text("Close", bundle: .module, comment: "accessibility label for the close-game button"))

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
                    .accessibilityIdentifier("label.score")
            }

            Spacer()

            Text("Block Blast", bundle: .module)
                .font(.title3)
                .fontWeight(.heavy)
                .foregroundStyle(Color.white)
                .accessibilityIdentifier("label.title")

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
                    .accessibilityIdentifier("label.bestScore")
            }

            Button(action: { showPauseMenu = true }) {
                Image("pause_circle", bundle: .module)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .accessibilityIdentifier("button.pause")
            .accessibilityLabel(Text("Pause", bundle: .module, comment: "accessibility label for the pause-menu button"))
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
                        let idx = row * GameModel.gridSize + col

                        cellView(
                            colorIndex: cellValue,
                            isHighlight: isHighlight,
                            isValidHighlight: highlightValid,
                            size: cs
                        )
                        .scaleEffect(placedScale[idx])
                        .offset(
                            x: originX + CGFloat(col) * cs,
                            y: originY + CGFloat(row) * cs
                        )
                    }
                }

                // Burst + ghost effects layer
                ForEach(0..<GameModel.gridSize, id: \.self) { row in
                    ForEach(0..<GameModel.gridSize, id: \.self) { col in
                        let idx = row * GameModel.gridSize + col
                        burstEffectCell(idx: idx, size: cs)
                            .offset(
                                x: originX + CGFloat(col) * cs,
                                y: originY + CGFloat(row) * cs
                            )
                            .allowsHitTesting(false)
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

    /// Renders the per-cell burst + ghost layer at a single grid position.
    /// The layer is empty during normal gameplay and lights up during a clear.
    func burstEffectCell(idx: Int, size: CGFloat) -> some View {
        let inset: CGFloat = 1.5
        let cellSide = size - inset * 2
        let ghostC = ghostColor[idx]
        let ghostS = ghostScale[idx]
        let ghostO = ghostOpacity[idx]
        let ghostR = ghostRotation[idx]
        let burstC = burstColor[idx]
        let burstS = burstScale[idx]
        let burstO = burstOpacity[idx]
        let flashO = flashOpacity[idx]

        return ZStack {
            // Pre-clear white flash — telegraphs that this cell is about to vanish
            if flashO > 0.0 {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white)
                    .frame(width: cellSide, height: cellSide)
                    .opacity(flashO)
            }
            // Expanding burst ring + filled halo
            if burstO > 0.0 {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(BlockColors.color(for: burstC), lineWidth: 3)
                    .frame(width: cellSide, height: cellSide)
                    .scaleEffect(burstS)
                    .opacity(burstO)
                RoundedRectangle(cornerRadius: 4)
                    .fill(BlockColors.color(for: burstC).opacity(0.4))
                    .frame(width: cellSide, height: cellSide)
                    .scaleEffect(burstS * 0.7)
                    .opacity(burstO)
            }
            // Ghost cell — the original colored block tumbling outward
            if ghostO > 0.0 && ghostC >= 0 {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(BlockColors.color(for: ghostC))
                        .frame(width: cellSide, height: cellSide)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.5), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: cellSide, height: cellSide)
                }
                .scaleEffect(ghostS)
                .rotationEffect(.degrees(Double(ghostR)))
                .opacity(ghostO)
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
                // Stretch the count-up so big four-digit gains feel weighty
                // (the timer fires every 20ms, so 25 steps ≈ 500ms).
                let steps: Int
                if diff > 2000 { steps = 40 }
                else if diff > 500 { steps = 25 }
                else if diff > 100 { steps = 15 }
                else { steps = 8 }
                let step = max(1, diff / steps)
                displayedScore = min(displayedScore + step, game.score)
            } else {
                displayedScore = game.score
            }
            changed = true
        }

        if displayedHighScore != game.highScore {
            let diff = game.highScore - displayedHighScore
            if diff > 0 {
                let steps: Int
                if diff > 2000 { steps = 40 }
                else if diff > 500 { steps = 25 }
                else if diff > 100 { steps = 15 }
                else { steps = 8 }
                let step = max(1, diff / steps)
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

                triggerPlacementAnimation()

                if game.lastLinesCleared > 0 {
                    triggerClearAnimation()
                } else {
                    playHaptic(.place)
                }

                if game.isGameOver {
                    playHaptic(.error)
                    triggerShake(intensity: 1.0)
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

    // MARK: - Animation Pipeline

    /// Trigger the squash-pulse animation on cells just placed by the player.
    func triggerPlacementAnimation() {
        let n = min(game.lastPlacedRows.count, game.lastPlacedCols.count)
        if n == 0 { return }
        let gs = GameModel.gridSize

        for i in 0..<n {
            let idx = game.lastPlacedRows[i] * gs + game.lastPlacedCols[i]
            if idx >= 0 && idx < placedScale.count {
                placedScale[idx] = 1.18
            }
        }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) {
            for i in 0..<n {
                let idx = game.lastPlacedRows[i] * gs + game.lastPlacedCols[i]
                if idx >= 0 && idx < placedScale.count {
                    placedScale[idx] = 1.0
                }
            }
        }
    }

    /// Choreograph the full burst pipeline for a line clear.
    /// Stages: flash → burst rings + ghost tumble → score popup → message.
    func triggerClearAnimation() {
        let gs = GameModel.gridSize
        let cleared = min(
            min(game.lastClearedRows.count, game.lastClearedCols.count),
            game.lastClearedColors.count
        )
        if cleared == 0 { return }

        let tier = EncouragingMessages.tier(
            linesCleared: game.lastLinesCleared,
            combo: game.comboStreak,
            boardCleared: game.boardCleared
        )

        // Stage 0 (immediate): pre-clear white flash to telegraph the kill.
        for i in 0..<cleared {
            let idx = game.lastClearedRows[i] * gs + game.lastClearedCols[i]
            if idx >= 0 && idx < flashOpacity.count {
                flashOpacity[idx] = 0.9
            }
        }
        withAnimation(.easeOut(duration: 0.18)) {
            for i in 0..<cleared {
                let idx = game.lastClearedRows[i] * gs + game.lastClearedCols[i]
                if idx >= 0 && idx < flashOpacity.count {
                    flashOpacity[idx] = 0.0
                }
            }
        }

        // Stage 1 (after 60ms): ghost tumble + burst rings begin.
        scheduleAnim(after: 0.06) {
            for i in 0..<cleared {
                let idx = game.lastClearedRows[i] * gs + game.lastClearedCols[i]
                if idx >= 0 && idx < ghostColor.count {
                    ghostColor[idx] = game.lastClearedColors[i]
                    ghostScale[idx] = 1.0
                    ghostOpacity[idx] = 1.0
                    ghostRotation[idx] = 0.0
                    burstColor[idx] = game.lastClearedColors[i]
                    burstScale[idx] = 1.0
                    burstOpacity[idx] = 0.9
                }
            }
            withAnimation(.easeOut(duration: 0.42)) {
                for i in 0..<cleared {
                    let idx = game.lastClearedRows[i] * gs + game.lastClearedCols[i]
                    if idx >= 0 && idx < ghostColor.count {
                        ghostScale[idx] = 1.6
                        ghostOpacity[idx] = 0.0
                        ghostRotation[idx] = CGFloat(((idx % 3) - 1) * 90)
                        burstScale[idx] = 2.4
                        burstOpacity[idx] = 0.0
                    }
                }
            }

            // Settle the ghost state once the animation finishes
            scheduleAnim(after: 0.5) {
                for i in 0..<cleared {
                    let idx = game.lastClearedRows[i] * gs + game.lastClearedCols[i]
                    if idx >= 0 && idx < ghostColor.count {
                        ghostColor[idx] = -1
                        ghostScale[idx] = 1.0
                        ghostOpacity[idx] = 0.0
                        ghostRotation[idx] = 0.0
                        burstScale[idx] = 0.0
                        burstOpacity[idx] = 0.0
                    }
                }
            }
        }

        // Stage 2: board pulse + camera shake (intensity scales with tier).
        let shakeIntensity: Double
        switch tier {
        case 1: shakeIntensity = 0.0
        case 2: shakeIntensity = 0.35
        case 3: shakeIntensity = 0.55
        case 4: shakeIntensity = 0.75
        case 5: shakeIntensity = 0.95
        case 6: shakeIntensity = 1.0
        default: shakeIntensity = 0.0
        }
        if shakeIntensity > 0.0 {
            triggerShake(intensity: shakeIntensity)
        }
        triggerBoardPulse(tier: tier)

        // Stage 3: encouraging-message popup.
        showMessagePopup(tier: tier)

        // Stage 4: floating "+points" score gain popup.
        showScoreGainPopup(tier: tier)

        // Stage 5: haptics (escalating with tier and combo).
        playClearHaptic(tier: tier, combo: game.comboStreak)

        // Stage 6: confetti shower on perfect board clear.
        if game.boardCleared {
            triggerConfetti()
        }
    }

    // MARK: - Animation Helpers

    func triggerBoardPulse(tier: Int) {
        boardPulse = 0.0
        withAnimation(.spring(response: 0.18, dampingFraction: 0.45)) {
            boardPulse = tier >= 4 ? 1.6 : 1.0
        }
        scheduleAnim(after: 0.22) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                boardPulse = 0.0
            }
        }
    }

    func showMessagePopup(tier: Int) {
        messageTier = tier
        messageIndex = EncouragingMessages.randomIndex(tier: tier)
        messageScale = 0.4
        messageOpacity = 0.0
        // Slight playful rotation for higher tiers.
        let wiggle: CGFloat
        switch tier {
        case 5: wiggle = -6
        case 6: wiggle = 4
        default: wiggle = 0
        }
        messageRotation = wiggle

        let popScale: CGFloat
        switch tier {
        case 1: popScale = 1.0
        case 2: popScale = 1.08
        case 3: popScale = 1.15
        case 4: popScale = 1.22
        case 5: popScale = 1.3
        case 6: popScale = 1.4
        default: popScale = 1.0
        }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
            messageScale = popScale
            messageOpacity = 1.0
            messageRotation = 0.0
        }

        let hold = tier >= 6 ? perfectMessageHoldDuration : messageHoldDuration
        scheduleAnim(after: hold) {
            withAnimation(.easeIn(duration: 0.4)) {
                messageOpacity = 0.0
                messageScale = popScale * 0.85
            }
        }
    }

    func showScoreGainPopup(tier: Int) {
        // The model has already added `lastScoreGain` to `score`; reading it
        // here guarantees the popup matches the running total.
        scoreGain = game.lastScoreGain
        scoreGainOffset = 0.0
        scoreGainOpacity = 1.0
        scoreGainScale = 0.6

        // Bigger tiers get a bigger pop so a four-digit gain reads louder than
        // a small line clear.
        let popScale: CGFloat
        switch tier {
        case 1: popScale = 1.15
        case 2: popScale = 1.3
        case 3: popScale = 1.5
        case 4: popScale = 1.7
        case 5: popScale = 1.9
        case 6: popScale = 2.1
        default: popScale = 1.2
        }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.55)) {
            scoreGainScale = popScale
        }
        withAnimation(.easeOut(duration: 1.3)) {
            scoreGainOffset = -110.0
            scoreGainOpacity = 0.0
        }
    }

    func triggerShake(intensity: Double) {
        let amplitude: CGFloat = CGFloat(10.0 * intensity)
        withAnimation(.linear(duration: 0.04)) {
            shakeOffsetX = amplitude
            shakeOffsetY = -amplitude * 0.4
        }
        scheduleAnim(after: 0.04) {
            withAnimation(.linear(duration: 0.04)) {
                shakeOffsetX = -amplitude * 0.85
                shakeOffsetY = amplitude * 0.35
            }
            scheduleAnim(after: 0.04) {
                withAnimation(.linear(duration: 0.04)) {
                    shakeOffsetX = amplitude * 0.55
                    shakeOffsetY = -amplitude * 0.2
                }
                scheduleAnim(after: 0.04) {
                    withAnimation(.linear(duration: 0.05)) {
                        shakeOffsetX = -amplitude * 0.3
                        shakeOffsetY = amplitude * 0.15
                    }
                    scheduleAnim(after: 0.05) {
                        withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) {
                            shakeOffsetX = 0.0
                            shakeOffsetY = 0.0
                        }
                    }
                }
            }
        }
    }

    func playClearHaptic(tier: Int, combo: Int) {
        switch tier {
        case 1:
            playHaptic(.celebrate)
        case 2:
            playHaptic(HapticPattern([
                HapticEvent(.tap, intensity: 0.85),
                HapticEvent(.tick, intensity: 0.7, delay: 0.06),
                HapticEvent(.tap, intensity: 0.9, delay: 0.06)
            ]))
        case 3:
            playHaptic(.bigCelebrate)
        case 4:
            playHaptic(HapticPattern([
                HapticEvent(.thud, intensity: 0.85),
                HapticEvent(.tap, intensity: 1.0, delay: 0.07),
                HapticEvent(.rise, intensity: 0.8, delay: 0.06),
                HapticEvent(.tap, intensity: 1.0, delay: 0.08),
                HapticEvent(.thud, intensity: 0.95, delay: 0.07)
            ]))
        case 5:
            playHaptic(.combo(streak: max(combo, 6)))
        case 6:
            // Perfect-clear flourish: rise into a thud cascade with a final fall.
            playHaptic(HapticPattern([
                HapticEvent(.rise, intensity: 1.0),
                HapticEvent(.thud, intensity: 1.0, delay: 0.10),
                HapticEvent(.thud, intensity: 1.0, delay: 0.06),
                HapticEvent(.tap, intensity: 1.0, delay: 0.05),
                HapticEvent(.tick, intensity: 0.9, delay: 0.04),
                HapticEvent(.tap, intensity: 1.0, delay: 0.05),
                HapticEvent(.thud, intensity: 1.0, delay: 0.06),
                HapticEvent(.fall, intensity: 0.9, delay: 0.10)
            ]))
        default:
            playHaptic(.celebrate)
        }
    }

    // MARK: - Confetti

    func triggerConfetti() {
        // Seed all confetti pieces at the top of the screen with random horizontal
        // velocity and a downward gravity. A repeating Timer steps physics until
        // every piece has faded.
        for i in 0..<confettiCount {
            confettiX[i] = CGFloat.random(in: 40.0...360.0)
            confettiY[i] = CGFloat.random(in: -40.0...80.0)
            confettiVX[i] = CGFloat.random(in: -2.0...2.0)
            confettiVY[i] = CGFloat.random(in: 2.0...5.0)
            confettiRotation[i] = CGFloat.random(in: 0.0...360.0)
            confettiRotationSpeed[i] = CGFloat.random(in: -8.0...8.0)
            confettiColor[i] = Int.random(in: 0..<7)
            confettiOpacity[i] = 1.0
        }
        confettiActive = true

        confettiTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { t in
            DispatchQueue.main.async {
                tickConfetti()
            }
        }
        confettiTimer = timer

        // Auto-stop after 2.4s
        scheduleAnim(after: 2.4) {
            confettiTimer?.invalidate()
            confettiTimer = nil
            confettiActive = false
            for i in 0..<confettiCount {
                confettiOpacity[i] = 0.0
            }
        }
    }

    func tickConfetti() {
        for i in 0..<confettiCount {
            if confettiOpacity[i] <= 0.0 { continue }
            confettiX[i] += confettiVX[i]
            confettiY[i] += confettiVY[i]
            confettiVY[i] += 0.18 // gravity
            confettiRotation[i] += confettiRotationSpeed[i]
            // Fade as the piece falls past the bottom of a typical screen
            if confettiY[i] > 700 {
                confettiOpacity[i] = max(0.0, confettiOpacity[i] - 0.08)
            }
        }
    }

    // MARK: - Animation Timers

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
        confettiTimer?.invalidate()
        confettiTimer = nil
    }

    func resetAllAnimationState() {
        let n = GameModel.gridSize * GameModel.gridSize
        for i in 0..<n {
            ghostColor[i] = -1
            ghostScale[i] = 1.0
            ghostOpacity[i] = 0.0
            ghostRotation[i] = 0.0
            burstColor[i] = 0
            burstScale[i] = 0.0
            burstOpacity[i] = 0.0
            flashOpacity[i] = 0.0
            placedScale[i] = 1.0
        }
        shakeOffsetX = 0.0
        shakeOffsetY = 0.0
        messageOpacity = 0.0
        messageScale = 0.0
        scoreGainOpacity = 0.0
        scoreGainOffset = 0.0
        comboPulse = 0.0
        boardPulse = 0.0
        for i in 0..<confettiCount {
            confettiOpacity[i] = 0.0
        }
        confettiActive = false
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
                    showDifficultyPicker = true
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
                    game.difficulty.label
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(game.difficulty.accentColor)
                }

                if game.score >= game.highScore && game.score > 0 {
                    Text("New High Score!", bundle: .module)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.yellow)
                }

                Button(action: {
                    showDifficultyPicker = true
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
                    item: "I scored \(game.score) in Block Blast on Faire Games! Can you beat it?\nhttps://appfair.net",
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

    // MARK: - Message + Score-Gain Popup

    /// Floating encouraging-message popup, colored and sized by `messageTier`.
    /// Tiers: 1 = white/small, 2 = cyan, 3 = yellow, 4 = orange, 5 = hot pink,
    /// 6 = rainbow (perfect board clear).
    var messagePopup: some View {
        VStack(spacing: 8) {
            if messageOpacity > 0.0 {
                messageLabel
            }

            if game.lastLinesCleared > 1 && messageOpacity > 0.0 {
                Text("\(game.lastLinesCleared)x Lines!", bundle: .module)
                    .font(.title3)
                    .fontWeight(.heavy)
                    .foregroundStyle(Color.yellow)
                    .scaleEffect(messageScale * 0.92)
                    .opacity(messageOpacity)
            }

            if game.comboStreak > 1 && messageOpacity > 0.0 {
                Text("Combo x\(game.comboStreak)!", bundle: .module)
                    .font(.title3)
                    .fontWeight(.heavy)
                    .foregroundStyle(Color.orange)
                    .scaleEffect(messageScale * 0.88)
                    .opacity(messageOpacity * 0.95)
            }

            if scoreGainOpacity > 0.0 && scoreGain > 0 {
                Text("+\(scoreGain)", bundle: .module)
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundStyle(tierColor(messageTier))
                    .scaleEffect(scoreGainScale)
                    .opacity(scoreGainOpacity)
                    .offset(y: scoreGainOffset)
                    .shadow(color: Color.black.opacity(0.6), radius: 4)
            }
        }
        .allowsHitTesting(false)
    }

    /// The big tier-coloured headline. The actual phrase is picked from a
    /// random pool keyed on the tier; see `EncouragingMessages` below.
    @ViewBuilder
    var messageLabel: some View {
        EncouragingMessages.text(tier: messageTier, index: messageIndex)
            .font(tierFont(messageTier))
            .fontWeight(.heavy)
            .foregroundStyle(tierColor(messageTier))
            .scaleEffect(messageScale)
            .rotationEffect(.degrees(Double(messageRotation)))
            .opacity(messageOpacity)
            .shadow(color: tierGlow(messageTier).opacity(0.85), radius: 14)
            .shadow(color: Color.black.opacity(0.7), radius: 4)
    }

    /// Font for the headline at each tier.
    func tierFont(_ tier: Int) -> Font {
        switch tier {
        case 1: return Font.title2.weight(.heavy)
        case 2: return Font.title.weight(.heavy)
        case 3: return Font.largeTitle.weight(.heavy)
        case 4: return Font.system(size: 44, weight: .black, design: .rounded)
        case 5: return Font.system(size: 52, weight: .black, design: .rounded)
        case 6: return Font.system(size: 56, weight: .black, design: .rounded)
        default: return Font.title2.weight(.bold)
        }
    }

    /// Solid color associated with each tier.
    func tierColor(_ tier: Int) -> Color {
        switch tier {
        case 1: return Color.white
        case 2: return Color.cyan
        case 3: return Color.yellow
        case 4: return Color.orange
        case 5: return Color(red: 1.0, green: 0.4, blue: 0.7)
        case 6: return Color(red: 1.0, green: 0.85, blue: 0.3)
        default: return Color.white
        }
    }

    /// Glow color for the message — usually matches the tier color but warmer.
    func tierGlow(_ tier: Int) -> Color {
        switch tier {
        case 1: return Color.white
        case 2: return Color.cyan
        case 3: return Color.yellow
        case 4: return Color.orange
        case 5: return Color(red: 1.0, green: 0.4, blue: 0.7)
        case 6: return Color(red: 1.0, green: 0.7, blue: 0.0)
        default: return Color.white
        }
    }

    // MARK: - Confetti Overlay

    var confettiOverlay: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<confettiCount, id: \.self) { i in
                    if confettiOpacity[i] > 0.0 {
                        Rectangle()
                            .fill(BlockColors.color(for: confettiColor[i]))
                            .frame(width: 10, height: 14)
                            .rotationEffect(.degrees(Double(confettiRotation[i])))
                            .opacity(Double(confettiOpacity[i]))
                            .position(
                                x: confettiX[i],
                                y: confettiY[i]
                            )
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
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

// MARK: - Difficulty

/// Three-tier difficulty for Block Blast. Replaces the old 0–10 slider so the
/// new-game flow matches Drop 7 / Sudoku: the player picks Easy, Normal, or
/// Hard at the start of every game and the chosen tier rides along in the
/// saved state. Each tier controls how aggressively the piece generator
/// retries to find a solvable set.
enum BlockBlastDifficulty: Int, CaseIterable, Identifiable {
    case easy = 0
    case normal = 1
    case hard = 2

    var id: Int { rawValue }

    /// Number of attempts the piece generator makes to find a *solvable* set
    /// of three pieces before falling back to whatever it last drew. Easy
    /// guarantees solvability, Normal usually does, Hard is pure random.
    var solvabilityAttempts: Int {
        switch self {
        case .easy: return 20
        case .normal: return 10
        case .hard: return 0
        }
    }

    /// Accent color used by the picker card and game-over difficulty chip.
    var accentColor: Color {
        switch self {
        case .easy:   return Color(red: 0.35, green: 0.75, blue: 0.45)
        case .normal: return Color(red: 0.30, green: 0.60, blue: 0.95)
        case .hard:   return Color(red: 0.90, green: 0.35, blue: 0.30)
        }
    }

    /// Localized one-word title for the tier. Inline `Text(literal, bundle:)`
    /// so the xcstrings extractor picks each variant up.
    @MainActor
    var label: Text {
        switch self {
        case .easy:
            return Text("Easy", bundle: .module, comment: "Block Blast difficulty: easy tier label")
        case .normal:
            return Text("Normal", bundle: .module, comment: "Block Blast difficulty: normal tier label")
        case .hard:
            return Text("Hard", bundle: .module, comment: "Block Blast difficulty: hard tier label")
        }
    }

    /// Localized one-line description shown under the tier label in the
    /// difficulty picker. Phrased factually rather than judgmentally so it
    /// reads the same way as the Drop 7 / Sudoku pickers.
    @MainActor
    var detail: Text {
        switch self {
        case .easy:
            return Text("Pieces always fit somewhere. Relaxed play.", bundle: .module, comment: "Block Blast picker: detail under the Easy tier")
        case .normal:
            return Text("Pieces usually fit. Balanced challenge.", bundle: .module, comment: "Block Blast picker: detail under the Normal tier")
        case .hard:
            return Text("Pieces are random. The board may become unwinnable.", bundle: .module, comment: "Block Blast picker: detail under the Hard tier")
        }
    }
}

// MARK: - Encouraging Messages

/// Tiered pool of encouraging headline phrases shown when the player clears
/// lines. Tiers escalate from a small "Nice!" up through a perfect-board
/// "Masterpiece!" so the visual reward matches the magnitude of the play.
///
/// All phrases use `bundle: .module` so they land in `Localizable.xcstrings`
/// and translate alongside the rest of the game. Adding a new phrase only
/// requires extending the `switch` and bumping the corresponding `count`.
struct EncouragingMessages {
    /// Pick a random message index for the given tier.
    static func randomIndex(tier: Int) -> Int {
        let n = count(tier: tier)
        if n <= 0 { return 0 }
        return Int.random(in: 0..<n)
    }

    /// Number of phrases defined for a given tier.
    static func count(tier: Int) -> Int {
        switch tier {
        case 1: return 5
        case 2: return 5
        case 3: return 5
        case 4: return 5
        case 5: return 5
        case 6: return 4
        default: return 1
        }
    }

    /// Compute the appropriate tier from a clear's magnitude.
    static func tier(linesCleared: Int, combo: Int, boardCleared: Bool) -> Int {
        if boardCleared { return 6 }
        if combo >= 7 || linesCleared >= 5 { return 5 }
        if combo >= 5 || linesCleared >= 4 { return 4 }
        if combo >= 3 || linesCleared >= 3 { return 3 }
        if combo >= 2 || linesCleared >= 2 { return 2 }
        return 1
    }

    /// Localized Text view for the given (tier, index) pair. The string
    /// literals must remain visible inline so they're picked up by the
    /// xcstrings extractor.
    static func text(tier: Int, index: Int) -> Text {
        switch tier {
        case 1:
            switch index {
            case 0: return Text("Nice!", bundle: .module, comment: "Tier 1 encouraging message after a small line clear")
            case 1: return Text("Good!", bundle: .module, comment: "Tier 1 encouraging message after a small line clear")
            case 2: return Text("Sweet!", bundle: .module, comment: "Tier 1 encouraging message after a small line clear")
            case 3: return Text("Cool!", bundle: .module, comment: "Tier 1 encouraging message after a small line clear")
            default: return Text("Clean!", bundle: .module, comment: "Tier 1 encouraging message after a small line clear")
            }
        case 2:
            switch index {
            case 0: return Text("Great!", bundle: .module, comment: "Tier 2 encouraging message after a 2-line clear or 2x combo")
            case 1: return Text("Nice Job!", bundle: .module, comment: "Tier 2 encouraging message after a 2-line clear or 2x combo")
            case 2: return Text("Smooth!", bundle: .module, comment: "Tier 2 encouraging message after a 2-line clear or 2x combo")
            case 3: return Text("Tasty!", bundle: .module, comment: "Tier 2 encouraging message after a 2-line clear or 2x combo")
            default: return Text("Slick!", bundle: .module, comment: "Tier 2 encouraging message after a 2-line clear or 2x combo")
            }
        case 3:
            switch index {
            case 0: return Text("Awesome!", bundle: .module, comment: "Tier 3 encouraging message after a 3-line clear or 3-4x combo")
            case 1: return Text("Excellent!", bundle: .module, comment: "Tier 3 encouraging message after a 3-line clear or 3-4x combo")
            case 2: return Text("Fantastic!", bundle: .module, comment: "Tier 3 encouraging message after a 3-line clear or 3-4x combo")
            case 3: return Text("Brilliant!", bundle: .module, comment: "Tier 3 encouraging message after a 3-line clear or 3-4x combo")
            default: return Text("Wonderful!", bundle: .module, comment: "Tier 3 encouraging message after a 3-line clear or 3-4x combo")
            }
        case 4:
            switch index {
            case 0: return Text("Amazing!", bundle: .module, comment: "Tier 4 encouraging message after a 4-line clear or 5-6x combo")
            case 1: return Text("Spectacular!", bundle: .module, comment: "Tier 4 encouraging message after a 4-line clear or 5-6x combo")
            case 2: return Text("Marvelous!", bundle: .module, comment: "Tier 4 encouraging message after a 4-line clear or 5-6x combo")
            case 3: return Text("Incredible!", bundle: .module, comment: "Tier 4 encouraging message after a 4-line clear or 5-6x combo")
            default: return Text("Outrageous!", bundle: .module, comment: "Tier 4 encouraging message after a 4-line clear or 5-6x combo")
            }
        case 5:
            switch index {
            case 0: return Text("UNBELIEVABLE!", bundle: .module, comment: "Tier 5 huge encouraging message after a 5+ line clear or 7+ combo")
            case 1: return Text("INSANE!", bundle: .module, comment: "Tier 5 huge encouraging message after a 5+ line clear or 7+ combo")
            case 2: return Text("LEGENDARY!", bundle: .module, comment: "Tier 5 huge encouraging message after a 5+ line clear or 7+ combo")
            case 3: return Text("GODLIKE!", bundle: .module, comment: "Tier 5 huge encouraging message after a 5+ line clear or 7+ combo")
            default: return Text("UNSTOPPABLE!", bundle: .module, comment: "Tier 5 huge encouraging message after a 5+ line clear or 7+ combo")
            }
        case 6:
            switch index {
            case 0: return Text("PERFECT CLEAR!", bundle: .module, comment: "Tier 6 perfect-board message when every cell is empty")
            case 1: return Text("FLAWLESS!", bundle: .module, comment: "Tier 6 perfect-board message when every cell is empty")
            case 2: return Text("MASTERPIECE!", bundle: .module, comment: "Tier 6 perfect-board message when every cell is empty")
            default: return Text("UNREAL!", bundle: .module, comment: "Tier 6 perfect-board message when every cell is empty")
            }
        default:
            return Text("Nice!", bundle: .module, comment: "Default encouraging message")
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
    /// Difficulty raw value chosen for this game. Required so a relaunched
    /// game resumes at the same tier the player started in.
    var difficultyRaw: Int
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

    /// Parallel arrays describing the cells cleared by the most recent move,
    /// captured *before* they were zeroed out so the view can render fading
    /// ghost blocks at their original colors. Length matches across all three.
    var lastClearedRows: [Int] = []
    var lastClearedCols: [Int] = []
    var lastClearedColors: [Int] = []

    /// Cells placed by the most recent move (row, col pairs). Used by the
    /// view to drive the squash-pulse animation on freshly placed cells.
    var lastPlacedRows: [Int] = []
    var lastPlacedCols: [Int] = []

    /// Total points awarded by the most recent move. The view reads this for
    /// the floating "+N" popup so the displayed number is always identical to
    /// what was actually added to `score`.
    var lastScoreGain: Int = 0

    /// Compute the score gain for a single move. Combines a per-cell placement
    /// bonus, a per-line bonus that grows quadratically with the number of
    /// lines cleared, a combo multiplier that *multiplies* the gain (vs the
    /// old additive bonus), and a flat board-clear bonus. The same formula is
    /// used by `placeShape` to update `score` and re-quoted via `lastScoreGain`
    /// so the popup never disagrees with the running total.
    static func computeMoveScore(
        cellsPlaced: Int,
        linesCleared: Int,
        comboStreak: Int,
        boardWillBeEmpty: Bool
    ) -> Int {
        let placementPoints = cellsPlaced * placementPointsPerCell
        // Quadratic line bonus: 1→100, 2→400, 3→900, 4→1600, 5→2500, 6→3600…
        let linePoints = linesCleared * linesCleared * basePointsPerLine
        let preMultGain = placementPoints + linePoints

        // Combo multiplier (multiplicative — much more rewarding than the
        // previous additive `comboStreak * 5` bonus).
        let multiplier: Double
        switch comboStreak {
        case 0, 1: multiplier = 1.0
        case 2: multiplier = 1.5
        case 3: multiplier = 2.0
        case 4: multiplier = 2.5
        case 5: multiplier = 3.0
        case 6: multiplier = 3.5
        default: multiplier = 4.0
        }

        let multipliedGain = Int(Double(preMultGain) * multiplier)
        let boardBonus = boardWillBeEmpty ? boardClearBonus : 0
        return multipliedGain + boardBonus
    }

    /// Difficulty tier for this game. Drives `solvabilityAttempts` and is
    /// persisted as part of the saved state so a relaunched game resumes at
    /// the same tier it started in.
    var difficulty: BlockBlastDifficulty = .normal

    /// Number of attempts to make when generating a solvable piece set.
    /// 0 means no validation (purely random), higher values try harder to
    /// find a solvable set. Derived from `difficulty`.
    var solvabilityAttempts: Int {
        return difficulty.solvabilityAttempts
    }

    init() {
        loadHighScore()
        spawnNewPieces()
    }

    // MARK: - Core Game Logic

    /// Start a fresh game. When `difficulty` is passed in, the model adopts
    /// it; pass `nil` to keep the current tier (used by tests and the
    /// "restore on first launch" path that doesn't go through the picker).
    func newGame(difficulty: BlockBlastDifficulty? = nil) {
        if let difficulty = difficulty {
            self.difficulty = difficulty
        }
        grid = Array(repeating: Array(repeating: -1, count: 8), count: 8)
        score = 0
        isGameOver = false
        lastLinesCleared = 0
        comboStreak = 0
        boardCleared = false
        clearingCells = []
        lastClearedRows = []
        lastClearedCols = []
        lastClearedColors = []
        lastPlacedRows = []
        lastPlacedCols = []
        lastScoreGain = 0
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
        // Reset cleared-cell tracking; clearCompletedLines may repopulate it.
        lastClearedRows = []
        lastClearedCols = []
        lastClearedColors = []

        // Capture which cells the player just placed (for placement animation)
        var placedR: [Int] = []
        var placedC: [Int] = []
        for cell in shape.cells {
            placedR.append(row + cell.row)
            placedC.append(col + cell.col)
        }
        lastPlacedRows = placedR
        lastPlacedCols = placedC

        // Place the cells
        for cell in shape.cells {
            let r = row + cell.row
            let c = col + cell.col
            grid[r][c] = shape.colorIndex
        }

        // Remove the placed piece
        currentPieces[pieceIndex] = nil

        // Check and clear completed lines
        let linesCleared = clearCompletedLines()
        lastLinesCleared = linesCleared

        if linesCleared > 0 {
            comboStreak += 1
        } else {
            comboStreak = 0
        }

        // Detect a full-board clear before computing the bonus.
        boardCleared = linesCleared > 0 && isBoardEmpty()

        // Roll the full move into a single score gain via the shared helper so
        // the floating popup and the running total always agree.
        let gain = GameModel.computeMoveScore(
            cellsPlaced: shape.cells.count,
            linesCleared: linesCleared,
            comboStreak: comboStreak,
            boardWillBeEmpty: boardCleared
        )
        lastScoreGain = gain
        score += gain

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

        // Capture the colors of cells about to be cleared so the view can
        // animate ghost blocks at their original colors after the model
        // zeroes the grid. Iterate the set deterministically by row, col.
        var lr: [Int] = []
        var lc: [Int] = []
        var lcol: [Int] = []
        for r in 0..<GameModel.gridSize {
            for c in 0..<GameModel.gridSize {
                if cellsToClear.contains(r * GameModel.gridSize + c) {
                    lr.append(r)
                    lc.append(c)
                    lcol.append(grid[r][c])
                }
            }
        }
        lastClearedRows = lr
        lastClearedCols = lc
        lastClearedColors = lcol

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
            boardCleared: boardCleared,
            difficultyRaw: difficulty.rawValue
        )
    }

    func restoreState(_ state: BlockBlastSavedState) {
        grid = state.grid
        score = state.score
        highScore = state.highScore
        isGameOver = state.isGameOver
        comboStreak = state.comboStreak
        boardCleared = state.boardCleared
        difficulty = BlockBlastDifficulty(rawValue: state.difficultyRaw) ?? .normal

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

// MARK: - Difficulty Picker Sheet

/// Sheet shown when starting a new Block Blast game. Mirrors the layout used
/// by Sudoku and Drop 7 — three accent-coloured cards with a description, plus
/// a checkmark on the currently-active tier.
struct BlockBlastDifficultyPickerView: View {
    let currentDifficulty: BlockBlastDifficulty
    let onSelect: (BlockBlastDifficulty) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Text("Choose Difficulty", bundle: .module, comment: "Block Blast difficulty picker: heading above the three tier cards")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                        .padding(.top, 10.0)

                    ForEach(BlockBlastDifficulty.allCases) { d in
                        Button(action: {
                            onSelect(d)
                            dismiss()
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    d.label
                                        .font(.title3)
                                        .fontWeight(.bold)
                                        .foregroundStyle(Color.white)
                                    d.detail
                                        .font(.caption)
                                        .foregroundStyle(Color.white.opacity(0.7))
                                }
                                Spacer()
                                if d == currentDifficulty {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(d.accentColor)
                                }
                            }
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(d.accentColor.opacity(0.18))
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(d.accentColor.opacity(0.5), lineWidth: 1.5)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("button.difficulty.\(d.rawValue)")
                    }
                }
                .padding(.horizontal, 20.0)
                .padding(.bottom, 24.0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.08, green: 0.08, blue: 0.18).ignoresSafeArea())
            .navigationTitle(Text("New Game", bundle: .module))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) { Text("Cancel", bundle: .module, comment: "Block Blast difficulty picker: cancel button in the toolbar") }
                        .foregroundStyle(Color.white)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Settings specific to the Block Blast game.
@Observable
public class BlockBlastSettings {
    /// Whether vibrations (haptic feedback) are enabled for Block Blast.
    public var vibrations: Bool = defaults.value(forKey: "blockBlastVibrations", default: true) {
        didSet { defaults.set(vibrations, forKey: "blockBlastVibrations") }
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
