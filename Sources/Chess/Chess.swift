// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import Observation
import SkipKit
import SkipModel
import FaireGamesModel
import SkipChess
// Skip's Kotlin transpiler doesn't follow @_exported umbrella re-exports,
// so the sub-modules are imported explicitly too.
import SkipChessModel
import SkipChessEngine
import SkipChessEngineAlphaBeta

// MARK: - Container

public struct ChessContainerView: View {
    @State private var settings = ChessSettings()
    @State private var showInstructions: Bool = false
    private let instructionsConfig = GameInstructionsConfig(
        key: "Chess.instructions",
        bundle: .module,
        firstLaunchKey: "instructionsShown_Chess",
        title: "Chess"
    )

    public init() { }

    public var body: some View {
        ChessRootView(showInstructions: $showInstructions)
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

// MARK: - Difficulty

/// Three-tier engine difficulty mapped to AlphaBeta search depth + time
/// budget. ELO estimates are approximations rather than measurements — they
/// give the player an intuitive sense of relative strength.
public enum ChessDifficulty: Int, CaseIterable, Identifiable, Codable {
    case easy = 0
    case medium = 1
    case hard = 2

    public var id: Int { rawValue }

    /// Maximum search depth in plies. Higher = stronger but slower.
    var searchDepth: Int {
        switch self {
        case .easy: return 2
        case .medium: return 4
        case .hard: return 6
        }
    }

    /// Wall-clock budget per move in milliseconds.
    var maxMilliseconds: Int64 {
        switch self {
        case .easy: return 250
        case .medium: return 1500
        case .hard: return 5000
        }
    }

    /// Approximate ELO rating (rough — actual strength depends on hardware).
    var approximateElo: Int {
        switch self {
        case .easy: return 800
        case .medium: return 1400
        case .hard: return 1900
        }
    }

    /// 0..1 probability of choosing a non-best legal move to humanize easy
    /// play. Hard never makes random moves.
    var blunderChance: Double {
        switch self {
        case .easy: return 0.25
        case .medium: return 0.05
        case .hard: return 0.0
        }
    }

    var accentColor: Color {
        switch self {
        case .easy:   return Color(red: 0.35, green: 0.75, blue: 0.45)
        case .medium: return Color(red: 0.30, green: 0.60, blue: 0.95)
        case .hard:   return Color(red: 0.90, green: 0.35, blue: 0.30)
        }
    }

    @MainActor
    var label: Text {
        switch self {
        case .easy:   return Text("Easy", bundle: .module, comment: "Chess difficulty: easy tier")
        case .medium: return Text("Medium", bundle: .module, comment: "Chess difficulty: medium tier")
        case .hard:   return Text("Hard", bundle: .module, comment: "Chess difficulty: hard tier")
        }
    }

    @MainActor
    var detail: Text {
        switch self {
        case .easy:   return Text("Friendly opponent. Occasional mistakes.", bundle: .module, comment: "Chess picker: detail under the Easy tier")
        case .medium: return Text("Solid play. Punishes obvious mistakes.", bundle: .module, comment: "Chess picker: detail under the Medium tier")
        case .hard:   return Text("Deep search. Few wasted moves.", bundle: .module, comment: "Chess picker: detail under the Hard tier")
        }
    }
}

// MARK: - Timer Strategy

/// Whether the game is timed, and if so, against what budget.
public enum ChessTimerStrategy: Int, CaseIterable, Identifiable, Codable {
    case off = 0
    case perMove = 1
    case totalGame = 2

    public var id: Int { rawValue }

    @MainActor
    var label: Text {
        switch self {
        case .off:       return Text("Untimed", bundle: .module, comment: "Chess timer strategy: no clock")
        case .perMove:   return Text("Per Move", bundle: .module, comment: "Chess timer strategy: each move has its own clock")
        case .totalGame: return Text("Total Game", bundle: .module, comment: "Chess timer strategy: one clock per side for the whole game")
        }
    }

    @MainActor
    var detail: Text {
        switch self {
        case .off:       return Text("No clock. Take all the time you want.", bundle: .module, comment: "Chess timer strategy detail: untimed")
        case .perMove:   return Text("A fresh budget for every move.", bundle: .module, comment: "Chess timer strategy detail: per-move clock")
        case .totalGame: return Text("One shared clock for the whole game.", bundle: .module, comment: "Chess timer strategy detail: total-game clock")
        }
    }
}

// MARK: - Theme

/// Visual theme. Affects board colors and piece silhouettes — see
/// `ChessPieceArt` for the piece-rendering side and `ChessBoardPalette` for
/// the board side. All five themes are first-party; nothing here mimics a
/// branded set.
public enum ChessTheme: Int, CaseIterable, Identifiable, Codable {
    case classic = 0
    case midnight = 1
    case forest = 2
    case sunset = 3
    case neon = 4

    public var id: Int { rawValue }

    @MainActor
    var label: Text {
        switch self {
        case .classic:  return Text("Classic", bundle: .module, comment: "Chess theme name: warm classic tan board")
        case .midnight: return Text("Midnight", bundle: .module, comment: "Chess theme name: dark blue board")
        case .forest:   return Text("Forest", bundle: .module, comment: "Chess theme name: green wood board")
        case .sunset:   return Text("Sunset", bundle: .module, comment: "Chess theme name: warm orange board")
        case .neon:     return Text("Neon", bundle: .module, comment: "Chess theme name: high-contrast neon board")
        }
    }
}

// MARK: - Board palette

/// Solid-colour palette used to render the board and highlights for a given
/// theme. Themes don't reach into Color directly — they go through this
/// struct so the rendering code only deals in named slots.
struct ChessBoardPalette: Sendable {
    let lightSquare: Color
    let darkSquare: Color
    let boardBorder: Color
    let labelColor: Color
    let lastMoveHighlight: Color
    let legalMoveDot: Color
    let selectionHalo: Color
    let checkHighlight: Color
    /// Solid colour used for white pieces in this theme.
    let whitePiece: Color
    /// Solid colour used for black pieces in this theme.
    let blackPiece: Color
    /// Thin outline drawn around every piece for legibility.
    let pieceOutline: Color
    /// Page background behind the board / HUD.
    let pageBackground: Color
    let panelBackground: Color
}

extension ChessTheme {
    var palette: ChessBoardPalette {
        switch self {
        case .classic:
            return ChessBoardPalette(
                lightSquare: Color(red: 0.93, green: 0.85, blue: 0.71),
                darkSquare: Color(red: 0.55, green: 0.39, blue: 0.27),
                boardBorder: Color(red: 0.20, green: 0.14, blue: 0.09),
                labelColor: Color(red: 0.95, green: 0.92, blue: 0.85).opacity(0.85),
                lastMoveHighlight: Color(red: 1.00, green: 0.92, blue: 0.45).opacity(0.55),
                legalMoveDot: Color(red: 0.25, green: 0.55, blue: 0.30),
                selectionHalo: Color(red: 1.0, green: 0.85, blue: 0.30),
                checkHighlight: Color(red: 0.95, green: 0.30, blue: 0.25),
                whitePiece: Color(red: 0.98, green: 0.95, blue: 0.90),
                blackPiece: Color(red: 0.20, green: 0.15, blue: 0.12),
                pieceOutline: Color(red: 0.15, green: 0.10, blue: 0.06).opacity(0.85),
                pageBackground: Color(red: 0.18, green: 0.13, blue: 0.09),
                panelBackground: Color(red: 0.30, green: 0.22, blue: 0.15)
            )
        case .midnight:
            return ChessBoardPalette(
                lightSquare: Color(red: 0.62, green: 0.68, blue: 0.82),
                darkSquare: Color(red: 0.22, green: 0.30, blue: 0.50),
                boardBorder: Color(red: 0.09, green: 0.10, blue: 0.16),
                labelColor: Color(red: 0.85, green: 0.90, blue: 1.0).opacity(0.85),
                lastMoveHighlight: Color(red: 0.50, green: 0.75, blue: 1.0).opacity(0.55),
                legalMoveDot: Color(red: 0.45, green: 0.85, blue: 0.95),
                selectionHalo: Color(red: 0.65, green: 0.85, blue: 1.0),
                checkHighlight: Color(red: 1.0, green: 0.45, blue: 0.55),
                whitePiece: Color(red: 0.96, green: 0.97, blue: 1.0),
                blackPiece: Color(red: 0.10, green: 0.10, blue: 0.18),
                pieceOutline: Color(red: 0.05, green: 0.07, blue: 0.13).opacity(0.85),
                pageBackground: Color(red: 0.07, green: 0.09, blue: 0.16),
                panelBackground: Color(red: 0.14, green: 0.17, blue: 0.30)
            )
        case .forest:
            return ChessBoardPalette(
                lightSquare: Color(red: 0.85, green: 0.83, blue: 0.65),
                darkSquare: Color(red: 0.28, green: 0.45, blue: 0.30),
                boardBorder: Color(red: 0.08, green: 0.18, blue: 0.10),
                labelColor: Color(red: 0.92, green: 0.95, blue: 0.82).opacity(0.85),
                lastMoveHighlight: Color(red: 0.85, green: 0.95, blue: 0.45).opacity(0.55),
                legalMoveDot: Color(red: 0.20, green: 0.55, blue: 0.25),
                selectionHalo: Color(red: 0.80, green: 0.95, blue: 0.40),
                checkHighlight: Color(red: 0.95, green: 0.40, blue: 0.30),
                whitePiece: Color(red: 0.96, green: 0.95, blue: 0.85),
                blackPiece: Color(red: 0.15, green: 0.20, blue: 0.13),
                pieceOutline: Color(red: 0.06, green: 0.12, blue: 0.06).opacity(0.85),
                pageBackground: Color(red: 0.09, green: 0.16, blue: 0.10),
                panelBackground: Color(red: 0.17, green: 0.30, blue: 0.20)
            )
        case .sunset:
            return ChessBoardPalette(
                lightSquare: Color(red: 0.98, green: 0.88, blue: 0.70),
                darkSquare: Color(red: 0.78, green: 0.36, blue: 0.30),
                boardBorder: Color(red: 0.30, green: 0.10, blue: 0.10),
                labelColor: Color(red: 1.0, green: 0.92, blue: 0.80).opacity(0.90),
                lastMoveHighlight: Color(red: 1.0, green: 0.75, blue: 0.40).opacity(0.60),
                legalMoveDot: Color(red: 0.80, green: 0.30, blue: 0.20),
                selectionHalo: Color(red: 1.0, green: 0.78, blue: 0.30),
                checkHighlight: Color(red: 0.95, green: 0.25, blue: 0.30),
                whitePiece: Color(red: 1.0, green: 0.96, blue: 0.88),
                blackPiece: Color(red: 0.22, green: 0.10, blue: 0.10),
                pieceOutline: Color(red: 0.18, green: 0.06, blue: 0.06).opacity(0.85),
                pageBackground: Color(red: 0.22, green: 0.09, blue: 0.08),
                panelBackground: Color(red: 0.38, green: 0.18, blue: 0.14)
            )
        case .neon:
            return ChessBoardPalette(
                lightSquare: Color(red: 0.20, green: 0.22, blue: 0.30),
                darkSquare: Color(red: 0.08, green: 0.09, blue: 0.15),
                boardBorder: Color(red: 0.02, green: 0.02, blue: 0.05),
                labelColor: Color(red: 0.65, green: 0.95, blue: 1.0).opacity(0.85),
                lastMoveHighlight: Color(red: 0.30, green: 1.0, blue: 0.70).opacity(0.55),
                legalMoveDot: Color(red: 0.30, green: 1.0, blue: 0.75),
                selectionHalo: Color(red: 1.0, green: 0.30, blue: 0.85),
                checkHighlight: Color(red: 1.0, green: 0.25, blue: 0.45),
                whitePiece: Color(red: 0.70, green: 1.0, blue: 0.95),
                blackPiece: Color(red: 1.0, green: 0.35, blue: 0.80),
                pieceOutline: Color.black.opacity(0.7),
                pageBackground: Color(red: 0.04, green: 0.04, blue: 0.10),
                panelBackground: Color(red: 0.10, green: 0.12, blue: 0.22)
            )
        }
    }
}

// MARK: - Captured-piece value helper

/// Material value of a piece kind. Used to scale haptic intensity and to
/// sort the captured-pieces strip so the most valuable piece sits leftmost.
struct ChessPieceValue {
    static func value(of kind: PieceKind) -> Int {
        switch kind {
        case .pawn: return 1
        case .knight: return 3
        case .bishop: return 3
        case .rook: return 5
        case .queen: return 9
        case .king: return 0 // king never gets captured
        }
    }
}

// MARK: - Settings

/// User-configurable preferences for the Chess game. Settings persist across
/// games; per-game state (difficulty, side, timer) is captured separately in
/// `ChessSavedState` so it round-trips with a paused game.
@Observable
public class ChessSettings {
    /// Whether haptic feedback is on at all.
    public var vibrations: Bool = defaults.value(forKey: "chessVibrations", default: true) {
        didSet { defaults.set(vibrations, forKey: "chessVibrations") }
    }
    /// Whether to draw a dot on every legal destination square when a piece
    /// is selected. Disabled by default so beginners aren't spoon-fed but is
    /// easy to find in settings.
    public var highlightLegalMoves: Bool = defaults.value(forKey: "chessHighlightLegalMoves", default: false) {
        didSet { defaults.set(highlightLegalMoves, forKey: "chessHighlightLegalMoves") }
    }
    /// Whether to draw the faint piece-coloured arrows showing each side's
    /// most recent move. Off by default — the highlighted from/to squares
    /// already convey the move and arrows add visual noise that some
    /// players find distracting.
    public var showLastMoveArrows: Bool = defaults.value(forKey: "chessShowLastMoveArrows", default: false) {
        didSet { defaults.set(showLastMoveArrows, forKey: "chessShowLastMoveArrows") }
    }
    /// Whether scrubbing the history slider commits an undo when the user
    /// lifts their finger off a past position. Off by default — scrubbing
    /// jumps back to the latest position on release, like a replay scrubber.
    public var allowUndo: Bool = defaults.value(forKey: "chessAllowUndo", default: false) {
        didSet { defaults.set(allowUndo, forKey: "chessAllowUndo") }
    }
    /// Selected visual theme, stored as the raw enum value.
    public var themeRaw: Int = defaults.value(forKey: "chessTheme", default: 0) {
        didSet { defaults.set(themeRaw, forKey: "chessTheme") }
    }
    public var theme: ChessTheme {
        get { ChessTheme(rawValue: themeRaw) ?? .classic }
        set { themeRaw = newValue.rawValue }
    }

    public init() {
    }
}

// MARK: - Saved game state

/// Persisted form of an in-progress game. Captured at every move and on
/// pause so the player can resume after a relaunch with the same difficulty,
/// side, timer, captured material, and full move history.
public struct ChessSavedState: Codable, Equatable {
    /// FEN of the position at the start of the game (always the standard
    /// starting FEN for now, but persisted so future variants don't break
    /// the save format).
    public var initialFEN: String
    /// UCI strings of every move played, in order. Replayed against the
    /// initial position to restore the full position + history.
    public var moveUCIs: [String]
    public var playerIsWhite: Bool
    public var difficultyRaw: Int
    public var timerStrategyRaw: Int
    /// Total budget for the chosen timer strategy in seconds. Per-move = the
    /// budget for one move; total-game = the budget for each side's full
    /// game. Ignored when timerStrategy == .off.
    public var timerBudgetSeconds: Int
    /// Seconds elapsed on the white clock so far.
    public var whiteElapsedSeconds: Double
    /// Seconds elapsed on the black clock so far.
    public var blackElapsedSeconds: Double
    /// Set when one side has lost on time. Game.result() doesn't track this
    /// (the clock is our concern, not the engine's).
    public var loserOnTimeRaw: Int
}

// MARK: - Game phase

/// The high-level state of the Chess view. Drives which sub-view is on
/// screen (start screen vs in-game) and the routing of various actions.
enum ChessPhase {
    case startScreen
    case playing
    case gameOver
}

// MARK: - Game outcome reason (mirrors GameResult plus our timer-loss case)

enum ChessOutcome: Equatable {
    case ongoing
    case whiteWinsByCheckmate
    case blackWinsByCheckmate
    case whiteWinsByTimeout
    case blackWinsByTimeout
    case whiteResigns
    case blackResigns
    case drawByStalemate
    case drawByInsufficientMaterial
    case drawByFiftyMoveRule
    case drawByThreefoldRepetition
    case drawByAgreement

    var isOngoing: Bool { self == .ongoing }
    var isDraw: Bool {
        switch self {
        case .drawByStalemate, .drawByInsufficientMaterial,
             .drawByFiftyMoveRule, .drawByThreefoldRepetition, .drawByAgreement:
            return true
        default: return false
        }
    }
    var whiteWon: Bool {
        switch self {
        case .whiteWinsByCheckmate, .whiteWinsByTimeout, .blackResigns: return true
        default: return false
        }
    }
    var blackWon: Bool {
        switch self {
        case .blackWinsByCheckmate, .blackWinsByTimeout, .whiteResigns: return true
        default: return false
        }
    }
}

// MARK: - Captured piece bookkeeping

/// One captured piece, stamped with the move number it fell on so the
/// captured-strip can sort and the history slider can scrub.
struct CapturedPiece: Hashable, Codable {
    let color: Int      // PieceColor.rawValue
    let kind: Int       // PieceKind.rawValue
    /// Ply (half-move) when this piece was captured.
    let capturedAtPly: Int

    var pieceColor: PieceColor {
        PieceColor(rawValue: color) ?? .white
    }
    var pieceKind: PieceKind {
        PieceKind(rawValue: kind) ?? .pawn
    }
    var pointValue: Int {
        ChessPieceValue.value(of: pieceKind)
    }
}


// MARK: - UserDefaults helpers (private to this module)

nonisolated(unsafe) private let defaults = UserDefaults.standard

private extension UserDefaults {
    func value<T>(forKey key: String, default defaultValue: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? defaultValue
    }
}

// MARK: - Game state (observable)

/// Owns the live `Game` from SkipChessModel plus everything the UI needs but
/// the model proper doesn't track: who the human player is, current
/// difficulty, timer state, captured material, history scrub index, and the
/// currently-running engine search task.
@MainActor
@Observable
final class ChessGameState {
    // MARK: Model
    /// The authoritative game state. Replayed from a FEN on restore.
    var game: Game

    // MARK: Player setup
    var playerIsWhite: Bool = true
    var difficulty: ChessDifficulty = .medium

    // MARK: Timer
    var timerStrategy: ChessTimerStrategy = .off
    /// Budget per move (.perMove) or per side (.totalGame) in seconds.
    var timerBudgetSeconds: Int = 600
    /// Elapsed seconds on each side's clock. For .perMove this is reset on
    /// each move; for .totalGame it accumulates.
    var whiteElapsedSeconds: Double = 0
    var blackElapsedSeconds: Double = 0
    /// Wall-clock instant the active side's clock started counting. nil when
    /// the clock is paused (e.g., engine thinking, view paused).
    var clockRunSince: Date? = nil
    /// Side that lost on the clock; .white = white lost; nil = no timeout.
    var loserOnTime: PieceColor? = nil

    // MARK: Captured material
    var capturedPieces: [CapturedPiece] = []

    // MARK: View state
    /// Square index of the currently selected piece (player's turn only).
    var selectedSquare: Int? = nil
    /// Cached legal moves for the selected piece.
    var selectedLegalMoves: [Move] = []
    /// (from, to) of the most recently played move, for the last-move highlight.
    var lastMoveFrom: Int = -1
    var lastMoveTo: Int = -1
    /// White's most recent (from, to) — used to draw the green arrow under
    /// the pieces. -1 = no white move played yet this game.
    var lastWhiteMoveFrom: Int = -1
    var lastWhiteMoveTo: Int = -1
    /// Black's most recent (from, to) — used to draw the orange arrow.
    var lastBlackMoveFrom: Int = -1
    var lastBlackMoveTo: Int = -1
    /// Animation state: a move currently being animated.
    var animatingMove: Move? = nil
    var animatingProgress: Double = 0.0

    /// History scrub index. `nil` means "show live position". An integer
    /// means "show the position after this many half-moves from the start".
    var scrubIndex: Int? = nil

    // MARK: Pending promotion
    /// When the player initiates a pawn move that would promote, the move's
    /// from/to is stashed here while the promotion picker is on screen. The
    /// player picks a kind and the move is finalised with the chosen
    /// promotion. nil = no promotion pending.
    var pendingPromotionFrom: Int = -1
    var pendingPromotionTo: Int = -1

    // MARK: Engine
    private var engineSearchTask: Task<Void, Never>? = nil

    // MARK: Outcome
    var outcome: ChessOutcome = .ongoing

    init() {
        // Start with a brand-new standard game; replaced on game start.
        self.game = Game(board: Board.standardStartingPosition(), initialFEN: FEN.startingPositionFEN)
    }

    /// Whether it is currently the human player's turn to move.
    var isPlayerTurn: Bool {
        let sideToMove = game.board.sideToMove
        if playerIsWhite { return sideToMove == PieceColor.white }
        return sideToMove == PieceColor.black
    }

    /// Total ply count played from the initial position.
    var totalPlies: Int { game.moveHistory.count }

    /// Whether the view is currently showing a scrubbed (past) position.
    var isScrubbing: Bool { scrubIndex != nil }

    // MARK: Game lifecycle

    /// Start a new game with the given configuration.
    func startNewGame(
        playerIsWhite: Bool,
        difficulty: ChessDifficulty,
        timerStrategy: ChessTimerStrategy,
        timerBudgetSeconds: Int
    ) {
        cancelEngineSearch()
        self.playerIsWhite = playerIsWhite
        self.difficulty = difficulty
        self.timerStrategy = timerStrategy
        self.timerBudgetSeconds = timerBudgetSeconds
        self.whiteElapsedSeconds = 0
        self.blackElapsedSeconds = 0
        self.clockRunSince = nil
        self.loserOnTime = nil
        self.capturedPieces = []
        self.selectedSquare = nil
        self.selectedLegalMoves = []
        self.lastMoveFrom = -1
        self.lastMoveTo = -1
        self.lastWhiteMoveFrom = -1
        self.lastWhiteMoveTo = -1
        self.lastBlackMoveFrom = -1
        self.lastBlackMoveTo = -1
        self.animatingMove = nil
        self.scrubIndex = nil
        self.pendingPromotionFrom = -1
        self.pendingPromotionTo = -1
        self.outcome = .ongoing
        self.game = Game(board: Board.standardStartingPosition(), initialFEN: FEN.startingPositionFEN)
    }

    /// Pump the timer by the seconds elapsed since the clock last ran. Called
    /// from the per-tick timer; idempotent if `clockRunSince` is nil.
    func tickClock(now: Date) {
        guard let started = clockRunSince else { return }
        guard outcome.isOngoing else { return }
        let elapsed = max(0.0, now.timeIntervalSince(started))
        clockRunSince = now
        let activeColor = game.board.sideToMove
        switch timerStrategy {
        case .off:
            // No clock; we shouldn't be ticking.
            clockRunSince = nil
            return
        case .perMove, .totalGame:
            if activeColor == PieceColor.white {
                whiteElapsedSeconds = whiteElapsedSeconds + elapsed
                if whiteElapsedSeconds >= Double(timerBudgetSeconds) {
                    handleTimeout(side: .white)
                }
            } else {
                blackElapsedSeconds = blackElapsedSeconds + elapsed
                if blackElapsedSeconds >= Double(timerBudgetSeconds) {
                    handleTimeout(side: .black)
                }
            }
        }
    }

    private func handleTimeout(side: PieceColor) {
        loserOnTime = side
        outcome = (side == .white) ? .blackWinsByTimeout : .whiteWinsByTimeout
        clockRunSince = nil
        cancelEngineSearch()
    }

    /// Start running the clock for the side currently to move.
    func startClockForActiveSide() {
        switch timerStrategy {
        case .off:
            return
        case .perMove:
            // Reset the side-to-move's clock at the start of their move.
            if game.board.sideToMove == PieceColor.white {
                whiteElapsedSeconds = 0
            } else {
                blackElapsedSeconds = 0
            }
        case .totalGame:
            break
        }
        clockRunSince = Date()
    }

    func pauseClock() {
        // Capture any in-progress time before stopping.
        tickClock(now: Date())
        clockRunSince = nil
    }

    // MARK: Move handling

    /// Returns the legal-move set for the piece at `from`. Used by the view
    /// to draw highlights and to validate taps on destination squares.
    func legalMovesFrom(_ from: Int) -> [Move] {
        var result: [Move] = []
        for m in game.board.legalMoves() {
            if m.from == from {
                result.append(m)
            }
        }
        return result
    }

    /// Tap-to-select / tap-to-move handler. Returns true if a move was
    /// actually played. `promotionKind` is consumed only when the move
    /// requires promotion (caller has shown the picker first).
    @discardableResult
    func attemptMove(from: Int, to: Int, promotion: PieceKind? = nil) -> Bool {
        guard isPlayerTurn else { return false }
        guard outcome.isOngoing else { return false }
        guard !isScrubbing else { return false }
        let candidates = legalMovesFrom(from)
        // Match a candidate whose destination matches and (if promotion)
        // whose promotion matches.
        var matched: Move? = nil
        for m in candidates {
            if m.to != to { continue }
            if m.isPromotion {
                if let kind = promotion, m.promotionKind == kind {
                    matched = m
                    break
                }
            } else {
                matched = m
                break
            }
        }
        guard let move = matched else { return false }
        commitMove(move, byPlayer: true)
        return true
    }

    /// Whether the move from→to is a promotion (so the view should show the
    /// promotion picker instead of finalising immediately).
    func isPromotionMove(from: Int, to: Int) -> Bool {
        for m in game.board.legalMoves() {
            if m.from == from && m.to == to && m.isPromotion {
                return true
            }
        }
        return false
    }

    /// Commit a fully-formed move to the model, updating captures, last-move
    /// highlight, clock, scrub index, and outcome. Then kick the engine if
    /// it's now the engine's turn.
    private func commitMove(_ move: Move, byPlayer: Bool) {
        // Capture material BEFORE the move is applied (en passant, etc.).
        let capturedCode = capturedPieceCodeFor(move)
        let played = game.play(move)
        guard played else { return }
        if capturedCode != 0 {
            recordCapture(pieceCode: capturedCode)
        }
        lastMoveFrom = move.from
        lastMoveTo = move.to
        // After play() the side-to-move has flipped — whichever side is NOT
        // to move now is the one that just played. Record the per-side last
        // move so the board can render two distinct arrows.
        let sideThatMoved: PieceColor = (game.board.sideToMove == PieceColor.white) ? PieceColor.black : PieceColor.white
        if sideThatMoved == PieceColor.white {
            lastWhiteMoveFrom = move.from
            lastWhiteMoveTo = move.to
        } else {
            lastBlackMoveFrom = move.from
            lastBlackMoveTo = move.to
        }
        selectedSquare = nil
        selectedLegalMoves = []
        scrubIndex = nil
        animatingMove = move
        animatingProgress = 0.0

        // Switch the clock to the new side-to-move.
        if timerStrategy != .off && outcome.isOngoing {
            // First stop the side that just moved.
            pauseClock()
            startClockForActiveSide()
        }

        updateOutcomeFromBoard()

        // Schedule engine reply when it's now the engine's turn.
        if outcome.isOngoing && !isPlayerTurn {
            requestEngineMove()
        }
    }

    /// Build the piece code that would be captured by `move` in the current
    /// position. Handles en passant explicitly because the captured pawn
    /// isn't on `move.to`.
    private func capturedPieceCodeFor(_ move: Move) -> Int {
        // En passant: a pawn moves diagonally to the empty en-passant square.
        if game.board.enPassantSquare == move.to,
           let p = game.board.piece(at: move.from), p.kind == PieceKind.pawn,
           Square.file(move.from) != Square.file(move.to) {
            let captureRow = (p.color == PieceColor.white) ? (Square.rank(move.to) - 1) : (Square.rank(move.to) + 1)
            let captureSq = Square.make(file: Square.file(move.to), rank: captureRow)
            return game.board.pieceCode(at: captureSq)
        }
        return game.board.pieceCode(at: move.to)
    }

    /// Add a captured piece (decoded from a PieceCode int) to the captured
    /// list, stamped with the current ply.
    private func recordCapture(pieceCode: Int) {
        if pieceCode == 0 { return }
        // PieceCode layout: bit 3 = color, low 3 bits = kind+1 (rough).
        // We decode by asking Board.piece(at:) before applying — but the
        // raw piece code is what we kept. Convert via Piece factory:
        // We rebuild via PieceColor/PieceKind from the code's interpretation.
        // Use Board.piece(at:) wasn't possible since the move was applied.
        // Decode the code via the public PieceCode static helpers if they
        // exist; if not, fall back to the kind/color from the lookup.
        let color: PieceColor = ChessGameState.colorFromCode(pieceCode)
        let kind: PieceKind = ChessGameState.kindFromCode(pieceCode)
        capturedPieces.append(CapturedPiece(
            color: color.rawValue,
            kind: kind.rawValue,
            capturedAtPly: game.moveHistory.count
        ))
    }

    /// Decode a non-empty `PieceCode` into a color. Code 1..6 = white, 9..14 = black
    /// (matching the convention used by SkipChessModel internally).
    private static func colorFromCode(_ code: Int) -> PieceColor {
        if code >= 9 { return .black }
        return .white
    }

    /// Decode a non-empty `PieceCode` into a piece kind. The low 3 bits
    /// indicate the kind (1..6 = pawn..king).
    private static func kindFromCode(_ code: Int) -> PieceKind {
        let raw = code & 7
        switch raw {
        case 1: return .pawn
        case 2: return .knight
        case 3: return .bishop
        case 4: return .rook
        case 5: return .queen
        case 6: return .king
        default: return .pawn
        }
    }

    private func updateOutcomeFromBoard() {
        guard let r = game.result() else { return }
        switch r {
        case GameResult.whiteWins(let reason):
            switch reason {
            case GameResult.WinReason.checkmate:   outcome = ChessOutcome.whiteWinsByCheckmate
            case GameResult.WinReason.resignation: outcome = ChessOutcome.blackResigns
            case GameResult.WinReason.timeout:     outcome = ChessOutcome.whiteWinsByTimeout
            }
        case GameResult.blackWins(let reason):
            switch reason {
            case GameResult.WinReason.checkmate:   outcome = ChessOutcome.blackWinsByCheckmate
            case GameResult.WinReason.resignation: outcome = ChessOutcome.whiteResigns
            case GameResult.WinReason.timeout:     outcome = ChessOutcome.blackWinsByTimeout
            }
        case GameResult.draw(let reason):
            switch reason {
            case GameResult.DrawReason.stalemate:            outcome = ChessOutcome.drawByStalemate
            case GameResult.DrawReason.insufficientMaterial: outcome = ChessOutcome.drawByInsufficientMaterial
            case GameResult.DrawReason.fiftyMoveRule:        outcome = ChessOutcome.drawByFiftyMoveRule
            case GameResult.DrawReason.threefoldRepetition:  outcome = ChessOutcome.drawByThreefoldRepetition
            case GameResult.DrawReason.fivefoldRepetition:   outcome = ChessOutcome.drawByThreefoldRepetition
            case GameResult.DrawReason.seventyFiveMoveRule:  outcome = ChessOutcome.drawByFiftyMoveRule
            case GameResult.DrawReason.agreement:            outcome = ChessOutcome.drawByAgreement
            }
        }
    }

    // MARK: Resign

    func resign() {
        let resigner = playerIsWhite ? PieceColor.white : PieceColor.black
        outcome = (resigner == PieceColor.white) ? ChessOutcome.blackResigns : ChessOutcome.whiteResigns
        clockRunSince = nil
        cancelEngineSearch()
    }

    // MARK: Engine

    /// Kick off an engine search. Cancels any in-flight search first. The
    /// search runs on a detached background task so the UI stays responsive;
    /// the resulting move is applied back on the main actor.
    func requestEngineMove() {
        cancelEngineSearch()
        let depth = difficulty.searchDepth
        let ms = difficulty.maxMilliseconds
        let blunder = difficulty.blunderChance
        // Snapshot the position via FEN — Sendable across the actor boundary.
        let fen = game.board.toFEN()
        engineSearchTask = Task.detached(priority: .userInitiated) {
            guard let snapshot = FEN.parse(fen) else { return }
            let engine = AlphaBetaEngine()
            let limits = SearchLimits(maxDepth: depth, maxNodes: nil, maxMilliseconds: ms)
            let result = engine.findBestMove(from: snapshot, limits: limits, control: nil, listener: nil)
            var chosen: Move? = result.bestMove
            // Blunder injection: with some probability pick a random legal
            // move instead of the engine's preferred one. Makes Easy feel
            // human-fallible without rewriting the evaluator.
            if blunder > 0.0 && chosen != nil {
                let roll = Double.random(in: 0.0...1.0)
                if roll < blunder {
                    let allMoves = snapshot.legalMoves()
                    if allMoves.count > 1 {
                        let idx = Int.random(in: 0..<allMoves.count)
                        chosen = allMoves[idx]
                    }
                }
            }
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.applyEngineMove(chosen)
            }
        }
    }

    private func applyEngineMove(_ move: Move?) {
        guard outcome.isOngoing else { return }
        // Only apply if the engine's expected side still matches the
        // current side to move (could race with resign / new game).
        if isPlayerTurn { return }
        guard let m = move else {
            // Engine returned nil — should already be reflected in outcome
            // via stalemate/checkmate, but refresh just in case.
            updateOutcomeFromBoard()
            return
        }
        commitMove(m, byPlayer: false)
    }

    func cancelEngineSearch() {
        engineSearchTask?.cancel()
        engineSearchTask = nil
    }

    // MARK: Persistence

    func makeSavedState() -> ChessSavedState {
        var ucis: [String] = []
        for mv in game.moveHistory {
            ucis.append(mv.uci)
        }
        let loserRaw: Int
        if let loser = loserOnTime {
            loserRaw = (loser == PieceColor.white) ? 1 : 2
        } else {
            loserRaw = 0
        }
        return ChessSavedState(
            initialFEN: game.initialFEN,
            moveUCIs: ucis,
            playerIsWhite: playerIsWhite,
            difficultyRaw: difficulty.rawValue,
            timerStrategyRaw: timerStrategy.rawValue,
            timerBudgetSeconds: timerBudgetSeconds,
            whiteElapsedSeconds: whiteElapsedSeconds,
            blackElapsedSeconds: blackElapsedSeconds,
            loserOnTimeRaw: loserRaw
        )
    }

    /// Replay a saved state into this instance. Resets everything to match
    /// the saved game's position and clocks.
    @discardableResult
    func restore(_ state: ChessSavedState) -> Bool {
        cancelEngineSearch()
        guard let board = FEN.parse(state.initialFEN) else { return false }
        let newGame = Game(board: board, initialFEN: state.initialFEN)
        // Replay moves one at a time, validating each is legal before
        // applying. If a move is rejected we abort so we never end up with
        // a partial restore that disagrees with the saved-state ply count.
        var capturedSoFar: [CapturedPiece] = []
        for uci in state.moveUCIs {
            guard let move = parseUCIMove(uci, on: newGame.board) else { return false }
            let preCapCode = capturedCodeForRestore(move: move, board: newGame.board)
            if !newGame.play(move) { return false }
            if preCapCode != 0 {
                let c = ChessGameState.colorFromCode(preCapCode)
                let k = ChessGameState.kindFromCode(preCapCode)
                capturedSoFar.append(CapturedPiece(
                    color: c.rawValue,
                    kind: k.rawValue,
                    capturedAtPly: newGame.moveHistory.count
                ))
            }
        }
        self.game = newGame
        self.playerIsWhite = state.playerIsWhite
        self.difficulty = ChessDifficulty(rawValue: state.difficultyRaw) ?? .medium
        self.timerStrategy = ChessTimerStrategy(rawValue: state.timerStrategyRaw) ?? .off
        self.timerBudgetSeconds = state.timerBudgetSeconds
        self.whiteElapsedSeconds = state.whiteElapsedSeconds
        self.blackElapsedSeconds = state.blackElapsedSeconds
        self.clockRunSince = nil
        self.capturedPieces = capturedSoFar
        self.selectedSquare = nil
        self.selectedLegalMoves = []
        if let last = newGame.moveHistory.last {
            self.lastMoveFrom = last.from
            self.lastMoveTo = last.to
        } else {
            self.lastMoveFrom = -1
            self.lastMoveTo = -1
        }
        // Recover the per-side last move from the move history so the arrow
        // overlay still reflects both arrows after a restore. Standard chess
        // alternates white/black starting with white; even indices = white.
        self.lastWhiteMoveFrom = -1
        self.lastWhiteMoveTo = -1
        self.lastBlackMoveFrom = -1
        self.lastBlackMoveTo = -1
        for i in 0..<newGame.moveHistory.count {
            let mv = newGame.moveHistory[i]
            if i % 2 == 0 {
                lastWhiteMoveFrom = mv.from
                lastWhiteMoveTo = mv.to
            } else {
                lastBlackMoveFrom = mv.from
                lastBlackMoveTo = mv.to
            }
        }
        self.animatingMove = nil
        self.scrubIndex = nil
        switch state.loserOnTimeRaw {
        case 1: self.loserOnTime = .white
        case 2: self.loserOnTime = .black
        default: self.loserOnTime = nil
        }
        self.outcome = .ongoing
        updateOutcomeFromBoard()
        if loserOnTime == .white { self.outcome = .blackWinsByTimeout }
        if loserOnTime == .black { self.outcome = .whiteWinsByTimeout }
        return true
    }

    /// Pre-move capture detection used by `restore` — same logic as
    /// `capturedPieceCodeFor` but operating on an arbitrary board (the one
    /// we're replaying into) rather than `self.game.board`.
    private func capturedCodeForRestore(move: Move, board: Board) -> Int {
        if board.enPassantSquare == move.to,
           let p = board.piece(at: move.from), p.kind == PieceKind.pawn,
           Square.file(move.from) != Square.file(move.to) {
            let captureRow = (p.color == PieceColor.white) ? (Square.rank(move.to) - 1) : (Square.rank(move.to) + 1)
            let captureSq = Square.make(file: Square.file(move.to), rank: captureRow)
            return board.pieceCode(at: captureSq)
        }
        return board.pieceCode(at: move.to)
    }

    // MARK: Scrub

    /// Reconstruct the board at `ply` (0 = before any move was played, N =
    /// after N moves). Used by the history scrubber to show a past position
    /// without mutating the live game.
    func boardAtPly(_ ply: Int) -> Board {
        let clamped = max(0, min(ply, game.moveHistory.count))
        guard let starting = FEN.parse(game.initialFEN) else {
            return Board.standardStartingPosition()
        }
        for i in 0..<clamped {
            _ = starting.makeMove(game.moveHistory[i])
        }
        return starting
    }

    /// Last-move highlight pair for the scrubbed position. -1 = none.
    func lastMoveAtPly(_ ply: Int) -> (Int, Int) {
        if ply <= 0 || ply > game.moveHistory.count {
            return (-1, -1)
        }
        let m = game.moveHistory[ply - 1]
        return (m.from, m.to)
    }
}

// MARK: - UCI move parser

/// Parse a UCI move ("e2e4" / "e7e8q") against a position to recover the
/// fully-typed Move. Returns nil if the string doesn't decode to a legal
/// move in the given position.
func parseUCIMove(_ uci: String, on board: Board) -> Move? {
    if uci.count < 4 { return nil }
    // Build a [String] from the UCI so we can slice safely on both Swift
    // and Skip (Array(String) needs an explicit Element type on Kotlin).
    let chars: [String] = uci.map { String($0) }
    let fromName = chars[0] + chars[1]
    let toName = chars[2] + chars[3]
    let from = Square.parse(fromName)
    let to = Square.parse(toName)
    if from < 0 || from >= 64 || to < 0 || to >= 64 { return nil }
    var promotion: Int = 0
    if chars.count >= 5 {
        let pc = chars[4]
        switch pc {
        case "q", "Q": promotion = PieceKind.queen.rawValue
        case "r", "R": promotion = PieceKind.rook.rawValue
        case "b", "B": promotion = PieceKind.bishop.rawValue
        case "n", "N": promotion = PieceKind.knight.rawValue
        default: promotion = 0
        }
    }
    let candidate = Move(from: from, to: to, promotion: promotion)
    // Verify against legal moves to handle inferred promotion / castling.
    for m in board.legalMoves() {
        if m.from == candidate.from && m.to == candidate.to && m.promotion == candidate.promotion {
            return m
        }
    }
    return nil
}


// MARK: - Piece set

/// Which open-source piece set a theme renders from. Each set is bundled as
/// PDF-backed image assets in `Module.xcassets` under the `piece_<set>_<XY>`
/// naming convention (X = w/b colour, Y = KQRBNP kind). Both sets are
/// GPL-2.0-or-later, matching Faire-Games' own licence — see CREDITS.md
/// for full attribution.
enum ChessPieceSet {
    /// Colin M. L. Burnett's Wikipedia chess set — the de-facto default.
    case cburnett
    /// Armando Hernandez Marroquin's Merida — sharper, more angular.
    case merida

    var assetPrefix: String {
        switch self {
        case .cburnett: return "piece_cburnett_"
        case .merida:   return "piece_merida_"
        }
    }
}

extension ChessTheme {
    /// Which open-source piece set this theme renders from.
    var pieceSet: ChessPieceSet {
        switch self {
        case .classic, .sunset, .neon: return .cburnett
        case .midnight, .forest:       return .merida
        }
    }
}

#if false
// Legacy hand-drawn vector silhouettes kept around for reference but disabled
// now that the GPL-2.0+ cburnett / merida sets render directly from assets.
// Re-enable this block if you want a Path-only fallback that doesn't depend
// on bundled image assets.
struct ChessPieceArt {
    /// Inner-square padding so the silhouette doesn't fill the cell edge to
    /// edge — leaves room for the last-move highlight and selection halo.
    static let inset: Double = 0.08

    /// Build a fully-rendered silhouette path for `kind` in `family` inside
    /// the unit square (0,0)–(1,1). Scale to `rect` before drawing.
    static func path(family: PieceArtFamily, kind: PieceKind, in rect: CGRect) -> Path {
        switch family {
        case .heritage:
            switch kind {
            case .pawn:   return heritagePawn(in: rect)
            case .knight: return heritageKnight(in: rect)
            case .bishop: return heritageBishop(in: rect)
            case .rook:   return heritageRook(in: rect)
            case .queen:  return heritageQueen(in: rect)
            case .king:   return heritageKing(in: rect)
            }
        case .modern:
            switch kind {
            case .pawn:   return modernPawn(in: rect)
            case .knight: return modernKnight(in: rect)
            case .bishop: return modernBishop(in: rect)
            case .rook:   return modernRook(in: rect)
            case .queen:  return modernQueen(in: rect)
            case .king:   return modernKing(in: rect)
            }
        }
    }

    // Helper: map a 0..1 point to the destination rect.
    private static func pt(_ x: Double, _ y: Double, in rect: CGRect) -> CGPoint {
        return CGPoint(
            x: rect.minX + CGFloat(x) * rect.width,
            y: rect.minY + CGFloat(y) * rect.height
        )
    }

    // MARK: Heritage family

    static func heritagePawn(in rect: CGRect) -> Path {
        return Path { p in
            // Head — disc near the top
            let head = CGRect(
                x: rect.minX + rect.width * 0.36,
                y: rect.minY + rect.height * 0.13,
                width: rect.width * 0.28,
                height: rect.height * 0.28
            )
            p.addEllipse(in: head)
            // Body — bell silhouette
            p.move(to: pt(0.42, 0.40, in: rect))
            p.addQuadCurve(to: pt(0.30, 0.65, in: rect), control: pt(0.36, 0.50, in: rect))
            p.addLine(to: pt(0.22, 0.85, in: rect))
            p.addLine(to: pt(0.78, 0.85, in: rect))
            p.addLine(to: pt(0.70, 0.65, in: rect))
            p.addQuadCurve(to: pt(0.58, 0.40, in: rect), control: pt(0.64, 0.50, in: rect))
            p.closeSubpath()
            // Base
            p.addRect(CGRect(
                x: rect.minX + rect.width * 0.18,
                y: rect.minY + rect.height * 0.85,
                width: rect.width * 0.64,
                height: rect.height * 0.07
            ))
        }
    }

    static func heritageKnight(in rect: CGRect) -> Path {
        return Path { p in
            // Stylised horse profile facing left.
            p.move(to: pt(0.27, 0.85, in: rect))
            p.addLine(to: pt(0.30, 0.60, in: rect))
            p.addQuadCurve(to: pt(0.22, 0.45, in: rect), control: pt(0.24, 0.50, in: rect))
            p.addQuadCurve(to: pt(0.30, 0.28, in: rect), control: pt(0.22, 0.35, in: rect))
            p.addQuadCurve(to: pt(0.48, 0.13, in: rect), control: pt(0.36, 0.18, in: rect))
            p.addQuadCurve(to: pt(0.70, 0.18, in: rect), control: pt(0.60, 0.10, in: rect))
            p.addQuadCurve(to: pt(0.76, 0.30, in: rect), control: pt(0.74, 0.22, in: rect))
            p.addLine(to: pt(0.66, 0.34, in: rect))
            p.addQuadCurve(to: pt(0.70, 0.42, in: rect), control: pt(0.66, 0.38, in: rect))
            p.addLine(to: pt(0.62, 0.50, in: rect))
            p.addQuadCurve(to: pt(0.70, 0.65, in: rect), control: pt(0.64, 0.58, in: rect))
            p.addLine(to: pt(0.74, 0.85, in: rect))
            p.closeSubpath()
            // Base
            p.addRect(CGRect(
                x: rect.minX + rect.width * 0.18,
                y: rect.minY + rect.height * 0.85,
                width: rect.width * 0.64,
                height: rect.height * 0.07
            ))
        }
    }

    static func heritageBishop(in rect: CGRect) -> Path {
        return Path { p in
            // Mitre head (pointed almond)
            p.move(to: pt(0.50, 0.10, in: rect))
            p.addQuadCurve(to: pt(0.62, 0.30, in: rect), control: pt(0.62, 0.18, in: rect))
            p.addQuadCurve(to: pt(0.50, 0.42, in: rect), control: pt(0.62, 0.40, in: rect))
            p.addQuadCurve(to: pt(0.38, 0.30, in: rect), control: pt(0.38, 0.40, in: rect))
            p.addQuadCurve(to: pt(0.50, 0.10, in: rect), control: pt(0.38, 0.18, in: rect))
            p.closeSubpath()
            // Collar
            p.addRect(CGRect(
                x: rect.minX + rect.width * 0.40,
                y: rect.minY + rect.height * 0.42,
                width: rect.width * 0.20,
                height: rect.height * 0.06
            ))
            // Body bell
            p.move(to: pt(0.42, 0.48, in: rect))
            p.addQuadCurve(to: pt(0.30, 0.68, in: rect), control: pt(0.34, 0.56, in: rect))
            p.addLine(to: pt(0.22, 0.85, in: rect))
            p.addLine(to: pt(0.78, 0.85, in: rect))
            p.addLine(to: pt(0.70, 0.68, in: rect))
            p.addQuadCurve(to: pt(0.58, 0.48, in: rect), control: pt(0.66, 0.56, in: rect))
            p.closeSubpath()
            // Base
            p.addRect(CGRect(
                x: rect.minX + rect.width * 0.18,
                y: rect.minY + rect.height * 0.85,
                width: rect.width * 0.64,
                height: rect.height * 0.07
            ))
        }
    }

    static func heritageRook(in rect: CGRect) -> Path {
        return Path { p in
            // Crenellated top
            let topY = rect.minY + rect.height * 0.10
            let crenY = rect.minY + rect.height * 0.20
            // Five crenellations across the top
            let segWidth = rect.width * 0.60 / 5.0
            let startX = rect.minX + rect.width * 0.20
            p.move(to: CGPoint(x: startX, y: crenY))
            var x = startX
            for i in 0..<5 {
                let merlonHigh = (i % 2 == 0)
                let nextX = startX + segWidth * Double(i + 1)
                if merlonHigh {
                    p.addLine(to: CGPoint(x: x, y: topY))
                    p.addLine(to: CGPoint(x: nextX, y: topY))
                    p.addLine(to: CGPoint(x: nextX, y: crenY))
                } else {
                    p.addLine(to: CGPoint(x: x, y: crenY))
                    p.addLine(to: CGPoint(x: nextX, y: crenY))
                }
                x = nextX
            }
            p.addLine(to: CGPoint(x: startX + rect.width * 0.60, y: crenY))
            // Neck + body taper
            p.addLine(to: pt(0.74, 0.32, in: rect))
            p.addQuadCurve(to: pt(0.72, 0.55, in: rect), control: pt(0.72, 0.42, in: rect))
            p.addLine(to: pt(0.80, 0.85, in: rect))
            p.addLine(to: pt(0.20, 0.85, in: rect))
            p.addLine(to: pt(0.28, 0.55, in: rect))
            p.addQuadCurve(to: pt(0.26, 0.32, in: rect), control: pt(0.28, 0.42, in: rect))
            p.closeSubpath()
            // Base
            p.addRect(CGRect(
                x: rect.minX + rect.width * 0.18,
                y: rect.minY + rect.height * 0.85,
                width: rect.width * 0.64,
                height: rect.height * 0.07
            ))
        }
    }

    static func heritageQueen(in rect: CGRect) -> Path {
        return Path { p in
            // Crown with five points
            let baseY = rect.minY + rect.height * 0.28
            let tipY = rect.minY + rect.height * 0.08
            let dipY = rect.minY + rect.height * 0.16
            let startX = rect.minX + rect.width * 0.26
            let endX = rect.minX + rect.width * 0.74
            let segWidth = (endX - startX) / 4.0
            p.move(to: CGPoint(x: startX, y: baseY))
            for i in 0..<4 {
                let xMid = startX + segWidth * (Double(i) + 0.5)
                let xNext = startX + segWidth * Double(i + 1)
                let dipPoint = CGPoint(x: xMid, y: dipY)
                let nextTip = CGPoint(x: xNext, y: tipY)
                p.addLine(to: dipPoint)
                p.addLine(to: nextTip)
            }
            p.addLine(to: CGPoint(x: endX, y: baseY))
            // Body bell
            p.addLine(to: pt(0.78, 0.55, in: rect))
            p.addLine(to: pt(0.82, 0.85, in: rect))
            p.addLine(to: pt(0.18, 0.85, in: rect))
            p.addLine(to: pt(0.22, 0.55, in: rect))
            p.closeSubpath()
            // Base
            p.addRect(CGRect(
                x: rect.minX + rect.width * 0.14,
                y: rect.minY + rect.height * 0.85,
                width: rect.width * 0.72,
                height: rect.height * 0.07
            ))
        }
    }

    static func heritageKing(in rect: CGRect) -> Path {
        return Path { p in
            // Cross at top
            let crossCx = rect.minX + rect.width * 0.50
            let crossTop = rect.minY + rect.height * 0.04
            let armY = rect.minY + rect.height * 0.10
            // Vertical
            p.addRect(CGRect(
                x: crossCx - rect.width * 0.04,
                y: crossTop,
                width: rect.width * 0.08,
                height: rect.height * 0.20
            ))
            // Horizontal
            p.addRect(CGRect(
                x: crossCx - rect.width * 0.10,
                y: armY,
                width: rect.width * 0.20,
                height: rect.height * 0.06
            ))
            // Crown (single peak)
            p.move(to: pt(0.30, 0.30, in: rect))
            p.addQuadCurve(to: pt(0.50, 0.24, in: rect), control: pt(0.40, 0.24, in: rect))
            p.addQuadCurve(to: pt(0.70, 0.30, in: rect), control: pt(0.60, 0.24, in: rect))
            p.addLine(to: pt(0.74, 0.42, in: rect))
            p.addLine(to: pt(0.26, 0.42, in: rect))
            p.closeSubpath()
            // Body
            p.move(to: pt(0.28, 0.42, in: rect))
            p.addLine(to: pt(0.72, 0.42, in: rect))
            p.addLine(to: pt(0.78, 0.55, in: rect))
            p.addLine(to: pt(0.82, 0.85, in: rect))
            p.addLine(to: pt(0.18, 0.85, in: rect))
            p.addLine(to: pt(0.22, 0.55, in: rect))
            p.closeSubpath()
            // Base
            p.addRect(CGRect(
                x: rect.minX + rect.width * 0.14,
                y: rect.minY + rect.height * 0.85,
                width: rect.width * 0.72,
                height: rect.height * 0.07
            ))
        }
    }

    // MARK: Modern family — sharp, geometric silhouettes.

    static func modernPawn(in rect: CGRect) -> Path {
        return Path { p in
            // Square-faceted head + trapezoidal body
            p.move(to: pt(0.50, 0.14, in: rect))
            p.addLine(to: pt(0.62, 0.26, in: rect))
            p.addLine(to: pt(0.62, 0.40, in: rect))
            p.addLine(to: pt(0.70, 0.50, in: rect))
            p.addLine(to: pt(0.76, 0.85, in: rect))
            p.addLine(to: pt(0.24, 0.85, in: rect))
            p.addLine(to: pt(0.30, 0.50, in: rect))
            p.addLine(to: pt(0.38, 0.40, in: rect))
            p.addLine(to: pt(0.38, 0.26, in: rect))
            p.closeSubpath()
            p.addRect(CGRect(
                x: rect.minX + rect.width * 0.18,
                y: rect.minY + rect.height * 0.85,
                width: rect.width * 0.64,
                height: rect.height * 0.07
            ))
        }
    }

    static func modernKnight(in rect: CGRect) -> Path {
        return Path { p in
            // Angular horse profile
            p.move(to: pt(0.22, 0.85, in: rect))
            p.addLine(to: pt(0.28, 0.55, in: rect))
            p.addLine(to: pt(0.22, 0.42, in: rect))
            p.addLine(to: pt(0.32, 0.30, in: rect))
            p.addLine(to: pt(0.42, 0.16, in: rect))
            p.addLine(to: pt(0.60, 0.12, in: rect))
            p.addLine(to: pt(0.74, 0.22, in: rect))
            p.addLine(to: pt(0.76, 0.35, in: rect))
            p.addLine(to: pt(0.62, 0.40, in: rect))
            p.addLine(to: pt(0.68, 0.50, in: rect))
            p.addLine(to: pt(0.60, 0.58, in: rect))
            p.addLine(to: pt(0.72, 0.85, in: rect))
            p.closeSubpath()
            p.addRect(CGRect(
                x: rect.minX + rect.width * 0.18,
                y: rect.minY + rect.height * 0.85,
                width: rect.width * 0.64,
                height: rect.height * 0.07
            ))
        }
    }

    static func modernBishop(in rect: CGRect) -> Path {
        return Path { p in
            // Pointed mitre + trapezoidal body
            p.move(to: pt(0.50, 0.08, in: rect))
            p.addLine(to: pt(0.62, 0.32, in: rect))
            p.addLine(to: pt(0.58, 0.42, in: rect))
            p.addLine(to: pt(0.70, 0.55, in: rect))
            p.addLine(to: pt(0.78, 0.85, in: rect))
            p.addLine(to: pt(0.22, 0.85, in: rect))
            p.addLine(to: pt(0.30, 0.55, in: rect))
            p.addLine(to: pt(0.42, 0.42, in: rect))
            p.addLine(to: pt(0.38, 0.32, in: rect))
            p.closeSubpath()
            p.addRect(CGRect(
                x: rect.minX + rect.width * 0.18,
                y: rect.minY + rect.height * 0.85,
                width: rect.width * 0.64,
                height: rect.height * 0.07
            ))
        }
    }

    static func modernRook(in rect: CGRect) -> Path {
        return Path { p in
            // Sharp angular castle
            let topY = rect.minY + rect.height * 0.10
            let crenY = rect.minY + rect.height * 0.22
            let startX = rect.minX + rect.width * 0.22
            let segWidth = rect.width * 0.56 / 5.0
            p.move(to: CGPoint(x: startX, y: crenY))
            for i in 0..<5 {
                let merlonHigh = (i % 2 == 0)
                let nextX = startX + segWidth * Double(i + 1)
                if merlonHigh {
                    p.addLine(to: CGPoint(x: startX + segWidth * Double(i), y: topY))
                    p.addLine(to: CGPoint(x: nextX, y: topY))
                    p.addLine(to: CGPoint(x: nextX, y: crenY))
                } else {
                    p.addLine(to: CGPoint(x: nextX, y: crenY))
                }
            }
            p.addLine(to: pt(0.78, 0.32, in: rect))
            p.addLine(to: pt(0.72, 0.55, in: rect))
            p.addLine(to: pt(0.80, 0.85, in: rect))
            p.addLine(to: pt(0.20, 0.85, in: rect))
            p.addLine(to: pt(0.28, 0.55, in: rect))
            p.addLine(to: pt(0.22, 0.32, in: rect))
            p.closeSubpath()
            p.addRect(CGRect(
                x: rect.minX + rect.width * 0.16,
                y: rect.minY + rect.height * 0.85,
                width: rect.width * 0.68,
                height: rect.height * 0.07
            ))
        }
    }

    static func modernQueen(in rect: CGRect) -> Path {
        return Path { p in
            let tipY = rect.minY + rect.height * 0.06
            let baseY = rect.minY + rect.height * 0.30
            let dipY = rect.minY + rect.height * 0.18
            let startX = rect.minX + rect.width * 0.20
            let endX = rect.minX + rect.width * 0.80
            let segWidth = (endX - startX) / 5.0
            p.move(to: CGPoint(x: startX, y: baseY))
            for i in 0..<5 {
                let xMid = startX + segWidth * (Double(i) + 0.5)
                let xNext = startX + segWidth * Double(i + 1)
                p.addLine(to: CGPoint(x: xMid, y: dipY))
                p.addLine(to: CGPoint(x: xNext, y: tipY))
            }
            p.addLine(to: CGPoint(x: endX, y: baseY))
            p.addLine(to: pt(0.78, 0.55, in: rect))
            p.addLine(to: pt(0.84, 0.85, in: rect))
            p.addLine(to: pt(0.16, 0.85, in: rect))
            p.addLine(to: pt(0.22, 0.55, in: rect))
            p.closeSubpath()
            p.addRect(CGRect(
                x: rect.minX + rect.width * 0.12,
                y: rect.minY + rect.height * 0.85,
                width: rect.width * 0.76,
                height: rect.height * 0.07
            ))
        }
    }

    static func modernKing(in rect: CGRect) -> Path {
        return Path { p in
            // Sharp cross
            let crossCx = rect.minX + rect.width * 0.50
            p.addRect(CGRect(
                x: crossCx - rect.width * 0.05,
                y: rect.minY + rect.height * 0.04,
                width: rect.width * 0.10,
                height: rect.height * 0.22
            ))
            p.addRect(CGRect(
                x: crossCx - rect.width * 0.12,
                y: rect.minY + rect.height * 0.10,
                width: rect.width * 0.24,
                height: rect.height * 0.08
            ))
            // Body with angled shoulders
            p.move(to: pt(0.30, 0.30, in: rect))
            p.addLine(to: pt(0.70, 0.30, in: rect))
            p.addLine(to: pt(0.76, 0.42, in: rect))
            p.addLine(to: pt(0.78, 0.55, in: rect))
            p.addLine(to: pt(0.84, 0.85, in: rect))
            p.addLine(to: pt(0.16, 0.85, in: rect))
            p.addLine(to: pt(0.22, 0.55, in: rect))
            p.addLine(to: pt(0.24, 0.42, in: rect))
            p.closeSubpath()
            p.addRect(CGRect(
                x: rect.minX + rect.width * 0.12,
                y: rect.minY + rect.height * 0.85,
                width: rect.width * 0.76,
                height: rect.height * 0.07
            ))
        }
    }
}
#endif

// MARK: - Piece view

/// Renders a piece using the theme's open-source vector asset. The image
/// name follows the convention `piece_<set>_<color><kind>` — e.g.
/// `piece_cburnett_wK` for the cburnett white king. Both sets are GPL-2.0+
/// and bundled as PDFs with `preserves-vector-representation` so the
/// rendering stays crisp at any cell size.
struct ChessPieceView: View {
    let piece: Piece
    let theme: ChessTheme

    var body: some View {
        Image(assetName, bundle: .module)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }

    private var assetName: String {
        let colorChar = piece.color == PieceColor.white ? "w" : "b"
        let kindChar = ChessPieceView.kindLetter(piece.kind)
        return theme.pieceSet.assetPrefix + colorChar + kindChar
    }

    /// Single-letter piece designator matching the SVG / PDF filenames
    /// shipped in `Module.xcassets`.
    private static func kindLetter(_ kind: PieceKind) -> String {
        switch kind {
        case .king:   return "K"
        case .queen:  return "Q"
        case .rook:   return "R"
        case .bishop: return "B"
        case .knight: return "N"
        case .pawn:   return "P"
        }
    }
}


// MARK: - Root view (routes between start screen and game view)

struct ChessRootView: View {
    @Binding var showInstructions: Bool
    @State private var phase: ChessPhase = .startScreen
    @State private var game = ChessGameState()
    @Environment(ChessSettings.self) var settings: ChessSettings
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            settings.theme.palette.pageBackground.ignoresSafeArea()
            switch phase {
            case .startScreen:
                ChessStartView(
                    onStart: { playerIsWhite, difficulty, timerStrategy, timerSeconds in
                        game.startNewGame(
                            playerIsWhite: playerIsWhite,
                            difficulty: difficulty,
                            timerStrategy: timerStrategy,
                            timerBudgetSeconds: timerSeconds
                        )
                        phase = ChessPhase.playing
                        if !playerIsWhite {
                            // Engine plays the first move.
                            game.requestEngineMove()
                        }
                        if timerStrategy != ChessTimerStrategy.off {
                            game.startClockForActiveSide()
                        }
                    },
                    onResume: {
                        if let s = loadSavedState(), game.restore(s) {
                            phase = ChessPhase.playing
                            if game.timerStrategy != ChessTimerStrategy.off && game.outcome.isOngoing {
                                game.startClockForActiveSide()
                            }
                            if !game.isPlayerTurn && game.outcome.isOngoing {
                                game.requestEngineMove()
                            }
                        }
                    },
                    onShowInstructions: { showInstructions = true },
                    onQuit: { dismiss() },
                    hasSavedGame: loadSavedState() != nil
                )
            case .playing, .gameOver:
                ChessGameView(
                    game: game,
                    showInstructions: $showInstructions,
                    onNewGame: {
                        clearSavedState()
                        game.cancelEngineSearch()
                        phase = ChessPhase.startScreen
                    },
                    onQuit: { dismiss() }
                )
            }
        }
        .onChange(of: game.outcome) { _, new in
            if !new.isOngoing { phase = ChessPhase.gameOver }
        }
    }
}

// MARK: - Saved-state persistence

private let savedStateKey = "chess_saved_state"

private func loadSavedState() -> ChessSavedState? {
    guard let json = UserDefaults.standard.string(forKey: savedStateKey) else { return nil }
    guard let data = json.data(using: String.Encoding.utf8) else { return nil }
    return try? JSONDecoder().decode(ChessSavedState.self, from: data)
}

private func writeSavedState(_ state: ChessSavedState) {
    guard let data = try? JSONEncoder().encode(state) else { return }
    guard let json = String(data: data, encoding: String.Encoding.utf8) else { return }
    UserDefaults.standard.set(json, forKey: savedStateKey)
}

private func clearSavedState() {
    UserDefaults.standard.removeObject(forKey: savedStateKey)
}

/// Resets all Chess persisted state — used by the home-grid "Reset" menu.
public func resetChessSavedState() {
    UserDefaults.standard.removeObject(forKey: savedStateKey)
}

// MARK: - Start screen

struct ChessStartView: View {
    let onStart: (Bool, ChessDifficulty, ChessTimerStrategy, Int) -> Void
    let onResume: () -> Void
    let onShowInstructions: () -> Void
    let onQuit: () -> Void
    let hasSavedGame: Bool

    @Environment(ChessSettings.self) var settings: ChessSettings

    @State private var playerIsWhite: Bool = true
    @State private var difficulty: ChessDifficulty = .medium
    @State private var timerStrategy: ChessTimerStrategy = .off
    @State private var timerSecondsIndex: Int = 1
    /// Allowed budgets for each strategy. The slider picks an index into
    /// this list; per-move uses smaller increments, total-game larger.
    private let perMoveOptions: [Int] = [10, 20, 30, 60, 120]
    private let totalGameOptions: [Int] = [180, 300, 600, 900, 1800]

    var body: some View {
        let palette = settings.theme.palette
        ScrollView {
            VStack(spacing: 18) {
                Text("Chess", bundle: .module, comment: "Chess game start-screen title")
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .foregroundStyle(Color.white)
                    .padding(.top, 24)
                    .accessibilityIdentifier("label.title")

                // Side picker
                sectionHeader("Play As", commentKey: "Chess start screen: side picker header")
                HStack(spacing: 12) {
                    sideCard(isWhite: true)
                    sideCard(isWhite: false)
                }

                // Difficulty cards
                sectionHeader("Difficulty", commentKey: "Chess start screen: difficulty header")
                VStack(spacing: 10) {
                    ForEach(ChessDifficulty.allCases) { d in
                        difficultyCard(d)
                    }
                }

                // Timer
                sectionHeader("Clock", commentKey: "Chess start screen: clock section header")
                VStack(spacing: 10) {
                    ForEach(ChessTimerStrategy.allCases) { s in
                        timerCard(s)
                    }
                }

                // Budget slider (only when timer is on)
                if timerStrategy != ChessTimerStrategy.off {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Time Budget", bundle: .module, comment: "Chess start screen: label above the time-budget slider")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.white)
                            Spacer()
                            Text(formatBudgetLabel(seconds: selectedBudget))
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundStyle(Color.yellow)
                                .monospaced()
                        }
                        Slider(
                            value: Binding(
                                get: { Double(timerSecondsIndex) },
                                set: { timerSecondsIndex = max(0, min(Int($0.rounded()), budgetOptions.count - 1)) }
                            ),
                            in: 0.0...Double(budgetOptions.count - 1),
                            step: 1.0
                        )
                        .accessibilityIdentifier("slider.timeBudget")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14).fill(palette.panelBackground.opacity(0.6))
                    )
                }

                // Theme preview
                sectionHeader("Theme", commentKey: "Chess start screen: theme section header")
                themePreview

                // Buttons
                if hasSavedGame {
                    Button(action: onResume) {
                        Text("Resume Game", bundle: .module, comment: "Chess start screen: resume the saved game")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.30, green: 0.55, blue: 0.95))
                    .accessibilityIdentifier("button.resume")
                }

                Button(action: {
                    onStart(playerIsWhite, difficulty, timerStrategy, selectedBudget)
                }) {
                    Text("Start Game", bundle: .module, comment: "Chess start screen: begin a new game")
                        .font(.title3)
                        .fontWeight(.heavy)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.20, green: 0.70, blue: 0.40))
                .accessibilityIdentifier("button.startGame")

                HStack(spacing: 8) {
                    Button(action: onShowInstructions) {
                        Text("How to Play", bundle: .module, comment: "Chess start screen: open the instructions sheet")
                            .font(.subheadline)
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("button.howToPlay")
                    Button(action: onQuit) {
                        Text("Quit", bundle: .module, comment: "Chess start screen: leave to the home screen")
                            .font(.subheadline)
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("button.quit")
                }
                .padding(.bottom, 30)
            }
            .padding(.horizontal, 18)
        }
    }

    private var budgetOptions: [Int] {
        return (timerStrategy == ChessTimerStrategy.perMove) ? perMoveOptions : totalGameOptions
    }

    private var selectedBudget: Int {
        let opts = budgetOptions
        let idx = max(0, min(timerSecondsIndex, opts.count - 1))
        return opts[idx]
    }

    @ViewBuilder
    private func sectionHeader(_ key: String, commentKey: String) -> some View {
        HStack {
            Text(LocalizedStringKey(key), bundle: .module)
                .font(.headline)
                .fontWeight(.heavy)
                .foregroundStyle(Color.white.opacity(0.85))
            Spacer()
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func sideCard(isWhite: Bool) -> some View {
        let palette = settings.theme.palette
        let isSelected = playerIsWhite == isWhite
        Button(action: { playerIsWhite = isWhite }) {
            VStack(spacing: 8) {
                ChessPieceView(
                    piece: Piece(color: isWhite ? PieceColor.white : PieceColor.black, kind: PieceKind.king),
                    theme: settings.theme
                )
                .frame(width: 64, height: 64)
                if isWhite {
                    Text("White", bundle: .module, comment: "Chess side picker: white pieces")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                } else {
                    Text("Black", bundle: .module, comment: "Chess side picker: black pieces")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(isSelected ? Color.white.opacity(0.20) : palette.panelBackground.opacity(0.6)))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.white.opacity(0.7) : Color.white.opacity(0.15), lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(isWhite ? "button.side.white" : "button.side.black")
    }

    @ViewBuilder
    private func difficultyCard(_ d: ChessDifficulty) -> some View {
        let selected = d == difficulty
        Button(action: { difficulty = d }) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    d.label
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                    d.detail
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.75))
                    Text("ELO ≈ \(d.approximateElo)", bundle: .module, comment: "Chess difficulty card: approximate ELO rating, %lld is the estimated number")
                        .font(.caption2)
                        .foregroundStyle(d.accentColor)
                        .fontWeight(.semibold)
                }
                Spacer()
                if selected {
                    ChessCheckCircle(color: d.accentColor)
                        .frame(width: 22, height: 22)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(d.accentColor.opacity(0.18)))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(d.accentColor.opacity(0.55), lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("button.difficulty.\(d.rawValue)")
    }

    @ViewBuilder
    private func timerCard(_ s: ChessTimerStrategy) -> some View {
        let palette = settings.theme.palette
        let selected = s == timerStrategy
        Button(action: { timerStrategy = s; timerSecondsIndex = 1 }) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    s.label
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                    s.detail
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                Spacer()
                if selected {
                    ChessCheckCircle(color: Color.yellow)
                        .frame(width: 18, height: 18)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.yellow.opacity(0.15) : palette.panelBackground.opacity(0.5)))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Color.yellow.opacity(0.5) : Color.white.opacity(0.12), lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("button.timer.\(s.rawValue)")
    }

    private var themePreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ChessTheme.allCases) { theme in
                    themeCard(theme)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private func themeCard(_ theme: ChessTheme) -> some View {
        @Bindable var s = settings
        let selected = theme == settings.theme
        let palette = theme.palette
        Button(action: { s.theme = theme }) {
            VStack(spacing: 6) {
                ZStack {
                    miniBoardSwatch(palette: palette)
                    ChessPieceView(
                        piece: Piece(color: PieceColor.white, kind: PieceKind.knight),
                        theme: theme
                    )
                    .frame(width: 32, height: 32)
                }
                .frame(width: 64, height: 64)
                theme.label
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.white)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.white.opacity(0.15) : Color.white.opacity(0.05)))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Color.white.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("button.theme.\(theme.rawValue)")
    }

    private func miniBoardSwatch(palette: ChessBoardPalette) -> some View {
        let cells = 4
        return VStack(spacing: 0) {
            ForEach(0..<cells, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<cells, id: \.self) { col in
                        Rectangle()
                            .fill((row + col) % 2 == 0 ? palette.lightSquare : palette.darkSquare)
                    }
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func formatBudgetLabel(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60
        let s = seconds % 60
        if s == 0 { return "\(m)m" }
        return "\(m)m \(s)s"
    }
}


// MARK: - Game view

struct ChessGameView: View {
    @Bindable var game: ChessGameState
    @Binding var showInstructions: Bool
    let onNewGame: () -> Void
    let onQuit: () -> Void

    @Environment(ChessSettings.self) var settings: ChessSettings

    @State private var showPauseMenu: Bool = false
    @State private var showSettings: Bool = false
    @State private var showPromotionPicker: Bool = false
    @State private var showResignConfirm: Bool = false
    @State private var clockTimer: Timer? = nil
    @State private var scrubFraction: Double = 1.0
    @State private var isScrubbing: Bool = false

    var body: some View {
        let palette = settings.theme.palette
        // Whose turn it currently is. The captured strip on the same side
        // of the board as the side-to-move gets a small coloured dot as a
        // turn indicator. When the game is over, no one is "to move".
        let activeColor: PieceColor = game.game.board.sideToMove
        let ongoing: Bool = game.outcome.isOngoing
        let whiteToMove: Bool = ongoing && activeColor == PieceColor.white
        let blackToMove: Bool = ongoing && activeColor == PieceColor.black
        return VStack(spacing: 8) {
            topBar
            // Top spacer + bottom spacer flank the board cluster so it sits
            // vertically centred between the top bar and the history slider.
            Spacer(minLength: 0)

            // Top captured strip — sits next to the OPPONENT's side of the
            // board (black side when player is white; white side when
            // player is black). Indicator dot fires when that side is to
            // move.
            if game.playerIsWhite {
                capturedStrip(forCaptor: PieceColor.white, isToMove: blackToMove)
                    .frame(height: 36)
                    .accessibilityIdentifier("strip.captured.byWhite")
            } else {
                capturedStrip(forCaptor: PieceColor.black, isToMove: whiteToMove)
                    .frame(height: 36)
                    .accessibilityIdentifier("strip.captured.byBlack")
            }

            // The board fills the entire horizontal space.
            // Don't set an accessibility identifier on the wrapper — doing
            // so would cascade onto every child square and clobber their
            // own per-square ids ("square.e2" etc.). The wrapper is exposed
            // implicitly by the parent VStack.
            boardArea

            // Bottom captured strip — sits next to the PLAYER's side. The
            // indicator fires here when it's the player's turn.
            if game.playerIsWhite {
                capturedStrip(forCaptor: PieceColor.black, isToMove: whiteToMove)
                    .frame(height: 36)
                    .accessibilityIdentifier("strip.captured.byBlack")
            } else {
                capturedStrip(forCaptor: PieceColor.white, isToMove: blackToMove)
                    .frame(height: 36)
                    .accessibilityIdentifier("strip.captured.byWhite")
            }

            Spacer(minLength: 0)

            historySliderBar
                .padding(.horizontal, 8)
                .accessibilityIdentifier("slider.history")
        }
        .background(palette.pageBackground.ignoresSafeArea())
        .navigationBarBackButtonHidden()
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .sheet(isPresented: $showPauseMenu) {
            ChessPauseMenuView(
                game: game,
                onResume: { showPauseMenu = false },
                onNewGame: {
                    showPauseMenu = false
                    onNewGame()
                },
                onShowSettings: {
                    showPauseMenu = false
                    showSettings = true
                },
                onShowInstructions: {
                    showPauseMenu = false
                    showInstructions = true
                },
                onResign: {
                    showPauseMenu = false
                    showResignConfirm = true
                },
                onQuit: {
                    showPauseMenu = false
                    onQuit()
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            ChessSettingsView(settings: settings)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showPromotionPicker) {
            ChessPromotionPickerView(
                pieceColor: game.playerIsWhite ? PieceColor.white : PieceColor.black,
                theme: settings.theme,
                onPick: { kind in
                    showPromotionPicker = false
                    game.attemptMove(from: game.pendingPromotionFrom, to: game.pendingPromotionTo, promotion: kind)
                    game.pendingPromotionFrom = -1
                    game.pendingPromotionTo = -1
                    // Save state after every move.
                    writeSavedState(game.makeSavedState())
                }
            )
            .presentationDetents([.height(280)])
        }
        .confirmationDialog(
            Text("Resign Game?", bundle: .module, comment: "Chess: confirmation dialog title when resigning"),
            isPresented: $showResignConfirm
        ) {
            Button(role: .destructive) {
                game.resign()
                writeSavedState(game.makeSavedState())
            } label: {
                Text("Resign", bundle: .module, comment: "Chess: confirm resignation button")
            }
            Button(role: .cancel) { } label: {
                Text("Cancel", bundle: .module, comment: "Chess: dismiss resignation dialog")
            }
        }
        .overlay {
            if !game.outcome.isOngoing {
                gameOverOverlay
            }
        }
        .onAppear {
            startClockTimer()
        }
        .onDisappear {
            stopClockTimer()
            game.pauseClock()
            game.cancelEngineSearch()
        }
        .onChange(of: game.totalPlies) { _, _ in
            // Persist after each move (player or engine).
            writeSavedState(game.makeSavedState())
            scrubFraction = 1.0
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            // Close button — leaves the game and returns to the home grid.
            // Mirrors the other games' top-left close affordance.
            Button(action: { onQuit() }) {
                Image("close", bundle: .module)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .accessibilityIdentifier("button.close")
            .accessibilityLabel(Text("Close", bundle: .module, comment: "Chess: accessibility label for the close-game button"))

            // Top clock (opponent)
            clockLabel(forColor: game.playerIsWhite ? PieceColor.black : PieceColor.white)
                .accessibilityIdentifier("label.opponentClock")

            Spacer()

            Text("Chess", bundle: .module, comment: "Chess game title in the HUD")
                .font(.headline)
                .fontWeight(.heavy)
                .foregroundStyle(Color.white)

            Spacer()

            // Bottom clock (player)
            clockLabel(forColor: game.playerIsWhite ? PieceColor.white : PieceColor.black)
                .accessibilityIdentifier("label.playerClock")

            // Pause button — opens the pause sheet, which now hosts the
            // Settings entry (per the unified upper-right control).
            Button(action: { showPauseMenu = true }) {
                Image("pause_circle", bundle: .module)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .accessibilityIdentifier("button.pause")
            .accessibilityLabel(Text("Pause", bundle: .module, comment: "Chess: accessibility label for the pause-menu button"))
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    private func clockLabel(forColor color: PieceColor) -> some View {
        let elapsed = (color == PieceColor.white) ? game.whiteElapsedSeconds : game.blackElapsedSeconds
        let remaining: Double
        if game.timerStrategy == ChessTimerStrategy.off {
            remaining = -1
        } else {
            remaining = max(0.0, Double(game.timerBudgetSeconds) - elapsed)
        }
        return Group {
            if remaining < 0 {
                Text(" ")
            } else {
                Text(formatClock(remaining))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(remaining < 30.0 ? Color.red : Color.white)
                    .monospaced()
            }
        }
        .frame(minWidth: 56)
    }

    private func formatClock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let m = s / 60
        let r = s % 60
        let mStr = m < 10 ? "0\(m)" : "\(m)"
        let rStr = r < 10 ? "0\(r)" : "\(r)"
        return "\(mStr):\(rStr)"
    }

    // MARK: Captured strip

    /// Pieces the *captor* has taken, displayed left-to-right sorted by
    /// material value (most valuable first). Plus an "advantage" badge if
    /// this side is up material.
    private func capturedStrip(forCaptor captor: PieceColor, isToMove: Bool) -> some View {
        let pieces = piecesCaptured(by: captor)
        let advantage = materialAdvantage(for: captor)
        let palette = settings.theme.palette
        // The strip displays pieces belonging to the OPPOSITE side from the
        // captor — those are the pieces sitting next to the displayed side
        // of the board. The turn-indicator dot is rendered in that side's
        // piece colour so it visually identifies whose move it is.
        let displayedSide: PieceColor = captor == PieceColor.white ? PieceColor.black : PieceColor.white
        let dotColor: Color = displayedSide == PieceColor.white ? palette.whitePiece : palette.blackPiece
        let dotId: String = displayedSide == PieceColor.white ? "indicator.toMove.white" : "indicator.toMove.black"
        return HStack(spacing: 6) {
            if isToMove {
                ZStack {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 12, height: 12)
                    Circle()
                        .stroke(Color.white.opacity(0.65), lineWidth: 1)
                        .frame(width: 12, height: 12)
                }
                .accessibilityIdentifier(dotId)
            }
            ForEach(0..<pieces.count, id: \.self) { i in
                ChessPieceView(piece: pieces[i], theme: settings.theme)
                    .frame(width: 24, height: 24)
            }
            if advantage > 0 {
                Text("+\(advantage)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
    }

    /// All pieces captured by `captor`, sorted descending by material value.
    private func piecesCaptured(by captor: PieceColor) -> [Piece] {
        var result: [Piece] = []
        for c in game.capturedPieces {
            if c.pieceColor != captor {
                result.append(Piece(color: c.pieceColor, kind: c.pieceKind))
            }
        }
        // Bubble-sort by point value descending (Skip-friendly).
        var i = 0
        while i < result.count {
            var j = i + 1
            while j < result.count {
                if ChessPieceValue.value(of: result[j].kind) > ChessPieceValue.value(of: result[i].kind) {
                    let tmp = result[i]
                    result[i] = result[j]
                    result[j] = tmp
                }
                j = j + 1
            }
            i = i + 1
        }
        return result
    }

    private func materialAdvantage(for color: PieceColor) -> Int {
        var captorTotal = 0
        var opponentTotal = 0
        for c in game.capturedPieces {
            let v = c.pointValue
            if c.pieceColor == color {
                opponentTotal = opponentTotal + v
            } else {
                captorTotal = captorTotal + v
            }
        }
        return max(0, captorTotal - opponentTotal)
    }

    // MARK: Board area

    private var boardArea: some View {
        GeometryReader { geo in
            let side = geo.size.width
            ChessBoardView(
                game: game,
                theme: settings.theme,
                highlightLegalMoves: settings.highlightLegalMoves,
                showLastMoveArrows: settings.showLastMoveArrows,
                onSquareTap: handleSquareTap
            )
            .frame(width: side, height: side)
        }
        .aspectRatio(1.0, contentMode: .fit)
        .padding(.horizontal, 0)
    }

    // MARK: History slider

    private var historySliderBar: some View {
        let plies = game.totalPlies
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Move \(currentMoveNumber()) of \(plies)", bundle: .module, comment: "Chess history slider caption: shown above the slider")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.65))
                Spacer()
                if game.isScrubbing {
                    Text("Replay", bundle: .module, comment: "Chess history slider: badge while scrubbing past positions")
                        .font(.caption2)
                        .foregroundStyle(Color.yellow)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.yellow.opacity(0.15)))
                }
            }
            Slider(
                value: Binding(
                    get: { scrubFraction },
                    set: { newValue in
                        scrubFraction = newValue
                        let target = scrubIndexFor(fraction: newValue)
                        if target == plies {
                            game.scrubIndex = nil
                        } else {
                            game.scrubIndex = target
                        }
                        isScrubbing = true
                    }
                ),
                in: 0.0...1.0
            ) { editing in
                if !editing {
                    isScrubbing = false
                    handleSliderRelease()
                }
            }
            .tint(Color.yellow)
            .disabled(plies == 0)
        }
        .padding(.vertical, 4)
    }

    private func currentMoveNumber() -> Int {
        if let idx = game.scrubIndex {
            return idx
        }
        return game.totalPlies
    }

    private func scrubIndexFor(fraction: Double) -> Int {
        let n = game.totalPlies
        if n == 0 { return 0 }
        return Int(round(fraction * Double(n)))
    }

    private func handleSliderRelease() {
        let plies = game.totalPlies
        // If allow-undo is on AND user dropped on a past position, treat the
        // release as a commitment to undo back to that ply. Otherwise jump
        // back to the live position.
        @Bindable var s = settings
        if s.allowUndo, let target = game.scrubIndex, target < plies {
            // Undo moves until we reach the target.
            while game.totalPlies > target {
                _ = game.game.undoLastMove()
            }
            // Rebuild captured pieces by replaying. Simpler: clear and re-walk.
            rebuildCapturedAfterUndo()
            game.scrubIndex = nil
            game.lastMoveFrom = -1
            game.lastMoveTo = -1
            if let last = game.game.moveHistory.last {
                game.lastMoveFrom = last.from
                game.lastMoveTo = last.to
            }
            writeSavedState(game.makeSavedState())
            scrubFraction = 1.0
            // If it's now the engine's turn (it was before undo), engine moves.
            if !game.isPlayerTurn && game.outcome.isOngoing {
                game.requestEngineMove()
            }
        } else {
            // Snap back to live.
            game.scrubIndex = nil
            scrubFraction = 1.0
        }
    }

    private func rebuildCapturedAfterUndo() {
        guard let starting = FEN.parse(game.game.initialFEN) else {
            game.capturedPieces = []
            return
        }
        var captured: [CapturedPiece] = []
        for mv in game.game.moveHistory {
            let code = capturedCodeOnBoard(board: starting, move: mv)
            _ = starting.makeMove(mv)
            if code != 0 {
                let c = ChessGameState_colorFromCode(code)
                let k = ChessGameState_kindFromCode(code)
                captured.append(CapturedPiece(color: c.rawValue, kind: k.rawValue, capturedAtPly: 0))
            }
        }
        game.capturedPieces = captured
    }

    private func capturedCodeOnBoard(board: Board, move: Move) -> Int {
        if board.enPassantSquare == move.to,
           let p = board.piece(at: move.from), p.kind == PieceKind.pawn,
           Square.file(move.from) != Square.file(move.to) {
            let captureRow = (p.color == PieceColor.white) ? (Square.rank(move.to) - 1) : (Square.rank(move.to) + 1)
            let captureSq = Square.make(file: Square.file(move.to), rank: captureRow)
            return board.pieceCode(at: captureSq)
        }
        return board.pieceCode(at: move.to)
    }

    // MARK: Square tap

    private func handleSquareTap(_ sq: Int) {
        guard game.outcome.isOngoing else { return }
        // Don't accept input while scrubbing past positions.
        if game.isScrubbing { return }
        if !game.isPlayerTurn { return }

        // Same square tapped twice → deselect.
        if game.selectedSquare == sq {
            game.selectedSquare = nil
            game.selectedLegalMoves = []
            playHaptic(HapticPattern.pick)
            return
        }

        if let from = game.selectedSquare {
            // Try to move from→sq.
            var legalTo = false
            for m in game.selectedLegalMoves {
                if m.to == sq { legalTo = true; break }
            }
            if legalTo {
                let isPromo = game.isPromotionMove(from: from, to: sq)
                if isPromo {
                    game.pendingPromotionFrom = from
                    game.pendingPromotionTo = sq
                    showPromotionPicker = true
                    playHaptic(HapticPattern.snap)
                } else {
                    let captured = (game.game.board.piece(at: sq) != nil)
                    game.attemptMove(from: from, to: sq)
                    if captured {
                        playHaptic(captureHapticPattern(for: lastCapturedValue()))
                    } else {
                        playHaptic(HapticPattern.place)
                    }
                }
                return
            }
            // Tapped a different friendly piece → switch selection.
            if let p = game.game.board.piece(at: sq),
               (game.playerIsWhite ? p.color == PieceColor.white : p.color == PieceColor.black) {
                game.selectedSquare = sq
                game.selectedLegalMoves = game.legalMovesFrom(sq)
                playHaptic(HapticPattern.pick)
                return
            }
            // Empty tap → deselect.
            game.selectedSquare = nil
            game.selectedLegalMoves = []
            return
        }

        // No selection yet — pick up own piece if there is one.
        if let p = game.game.board.piece(at: sq),
           (game.playerIsWhite ? p.color == PieceColor.white : p.color == PieceColor.black) {
            game.selectedSquare = sq
            game.selectedLegalMoves = game.legalMovesFrom(sq)
            playHaptic(HapticPattern.pick)
        }
    }

    // MARK: Haptics

    private func playHaptic(_ pattern: HapticPattern) {
        @Bindable var s = settings
        if s.vibrations {
            HapticFeedback.play(pattern)
        }
    }

    /// Value of the piece captured by the most recent move (used to choose
    /// the haptic strength for the player's "good" capture feedback).
    private func lastCapturedValue() -> Int {
        if let last = game.capturedPieces.last { return last.pointValue }
        return 0
    }

    /// Strong "good vibrations" pattern. Pawn-1 light tap, queen-9 big
    /// rolling celebrate.
    private func captureHapticPattern(for value: Int) -> HapticPattern {
        let v = max(1, min(value, 9))
        // Build a layered pattern proportional to value.
        var events: [HapticEvent] = []
        events.append(HapticEvent(.tap, intensity: 0.50 + Double(v) * 0.05))
        if v >= 3 {
            events.append(HapticEvent(.tick, intensity: 0.60, delay: 0.05))
        }
        if v >= 5 {
            events.append(HapticEvent(.tap, intensity: 0.85, delay: 0.06))
        }
        if v >= 7 {
            events.append(HapticEvent(.rise, intensity: 0.95, delay: 0.05))
            events.append(HapticEvent(.thud, intensity: 1.0, delay: 0.08))
        }
        return HapticPattern(events)
    }

    /// Sharp "bad vibrations" pattern when the engine captures the player's
    /// piece. Inverts the build-up: a sharp lowTick + sting.
    private func captureLossHapticPattern(for value: Int) -> HapticPattern {
        let v = max(1, min(value, 9))
        var events: [HapticEvent] = []
        events.append(HapticEvent(.lowTick, intensity: 0.60 + Double(v) * 0.04))
        if v >= 3 {
            events.append(HapticEvent(.thud, intensity: 0.75, delay: 0.05))
        }
        if v >= 5 {
            events.append(HapticEvent(.lowTick, intensity: 0.90, delay: 0.06))
        }
        if v >= 7 {
            events.append(HapticEvent(.fall, intensity: 0.95, delay: 0.05))
            events.append(HapticEvent(.thud, intensity: 1.0, delay: 0.08))
        }
        return HapticPattern(events)
    }

    // MARK: Clock timer

    private func startClockTimer() {
        if clockTimer != nil { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            DispatchQueue.main.async {
                game.tickClock(now: Date())
            }
        }
        clockTimer = t
    }

    private func stopClockTimer() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    // MARK: Game-over overlay

    private var gameOverOverlay: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 16) {
                outcomeHeadline
                    .font(.largeTitle)
                    .fontWeight(.heavy)
                    .foregroundStyle(Color.white)
                outcomeDetail
                    .font(.headline)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                Button(action: onNewGame) {
                    Text("New Game", bundle: .module, comment: "Chess game-over: start a fresh game")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 200)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.20, green: 0.70, blue: 0.40))
                .accessibilityIdentifier("button.newGame")
                Button(action: onQuit) {
                    Text("Quit", bundle: .module, comment: "Chess game-over: back to home")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 200)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("button.quitGameOver")
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 20).fill(settings.theme.palette.panelBackground))
        }
    }

    @ViewBuilder
    private var outcomeHeadline: some View {
        switch game.outcome {
        case .ongoing:
            EmptyView()
        case .whiteWinsByCheckmate, .whiteWinsByTimeout, .blackResigns:
            if game.playerIsWhite {
                Text("You Win!", bundle: .module, comment: "Chess game-over: human player won")
            } else {
                Text("You Lose", bundle: .module, comment: "Chess game-over: human player lost")
            }
        case .blackWinsByCheckmate, .blackWinsByTimeout, .whiteResigns:
            if game.playerIsWhite {
                Text("You Lose", bundle: .module, comment: "Chess game-over: human player lost")
            } else {
                Text("You Win!", bundle: .module, comment: "Chess game-over: human player won")
            }
        case .drawByStalemate, .drawByInsufficientMaterial,
             .drawByFiftyMoveRule, .drawByThreefoldRepetition, .drawByAgreement:
            Text("Draw", bundle: .module, comment: "Chess game-over: draw")
        }
    }

    @ViewBuilder
    private var outcomeDetail: some View {
        switch game.outcome {
        case .ongoing:
            EmptyView()
        case .whiteWinsByCheckmate, .blackWinsByCheckmate:
            Text("Checkmate.", bundle: .module, comment: "Chess game-over: how the game ended (checkmate)")
        case .whiteWinsByTimeout, .blackWinsByTimeout:
            Text("Won on time.", bundle: .module, comment: "Chess game-over: how the game ended (timeout)")
        case .whiteResigns, .blackResigns:
            Text("Resigned.", bundle: .module, comment: "Chess game-over: how the game ended (resignation)")
        case .drawByStalemate:
            Text("Stalemate.", bundle: .module, comment: "Chess game-over: how the game ended (stalemate)")
        case .drawByInsufficientMaterial:
            Text("Insufficient material.", bundle: .module, comment: "Chess game-over: how the game ended (insufficient material)")
        case .drawByFiftyMoveRule:
            Text("Fifty-move rule.", bundle: .module, comment: "Chess game-over: how the game ended (fifty-move rule)")
        case .drawByThreefoldRepetition:
            Text("Threefold repetition.", bundle: .module, comment: "Chess game-over: how the game ended (threefold repetition)")
        case .drawByAgreement:
            Text("Draw by agreement.", bundle: .module, comment: "Chess game-over: how the game ended (draw by agreement)")
        }
    }
}

// MARK: - Top-level color-from-code helpers (used outside ChessGameState)

private func ChessGameState_colorFromCode(_ code: Int) -> PieceColor {
    if code >= 9 { return PieceColor.black }
    return PieceColor.white
}

private func ChessGameState_kindFromCode(_ code: Int) -> PieceKind {
    let raw = code & 7
    switch raw {
    case 1: return PieceKind.pawn
    case 2: return PieceKind.knight
    case 3: return PieceKind.bishop
    case 4: return PieceKind.rook
    case 5: return PieceKind.queen
    case 6: return PieceKind.king
    default: return PieceKind.pawn
    }
}


// MARK: - Board view

/// Renders the 8x8 board, pieces (from either the live game or a scrubbed
/// past position), highlights for last-move and selection, the legal-move
/// dot overlay, and tap targets that bubble up to the parent.
struct ChessBoardView: View {
    @Bindable var game: ChessGameState
    let theme: ChessTheme
    let highlightLegalMoves: Bool
    let showLastMoveArrows: Bool
    let onSquareTap: (Int) -> Void

    /// Animation progress for the most recent move's piece slide. 0 means
    /// the piece is rendered at its source square; 1 means it has reached
    /// its destination. The value is driven by `triggerSlideAnimation()` on
    /// every move via `.onChange(of: game.totalPlies)`.
    @State private var moveSlideProgress: Double = 1.0

    var body: some View {
        let palette = theme.palette
        // Choose whether to render the live game or a scrubbed past position.
        let scrubbing = game.scrubIndex != nil
        let displayBoard: Board = scrubbing ? game.boardAtPly(game.scrubIndex ?? game.totalPlies) : game.game.board
        let lastFrom: Int
        let lastTo: Int
        if let s = game.scrubIndex {
            let pair = game.lastMoveAtPly(s)
            lastFrom = pair.0
            lastTo = pair.1
        } else {
            lastFrom = game.lastMoveFrom
            lastTo = game.lastMoveTo
        }
        return GeometryReader { geo in
            let cellSide = geo.size.width / 8.0
            ZStack(alignment: .topLeading) {
                // Background frame.
                Rectangle()
                    .fill(palette.boardBorder)
                    .frame(width: geo.size.width, height: geo.size.height)

                // Layer 1 — squares + highlights. Rendered as a natural
                // VStack of HStacks so tap handlers compose correctly on
                // both SwiftUI and Skip's Compose backend (offset-based
                // positioning was unreliable for Android touch detection).
                VStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<8, id: \.self) { col in
                                let sq = squareForDisplayRowCol(row: row, col: col)
                                squareBackgroundView(sq: sq, cellSide: cellSide,
                                                     displayBoard: displayBoard,
                                                     lastFrom: lastFrom, lastTo: lastTo,
                                                     palette: palette)
                            }
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)

                // Layer 2 — faint arrows showing each side's most recent
                // move. Conditionally rendered (no framed wrapper when
                // suppressed) so it can't leave behind an invisible Box
                // that Skip's Compose backend would treat as a touch sink.
                if showLastMoveArrows && !scrubbing {
                    arrowsLayer(cellSide: cellSide)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                }

                // Layer 3 — single sliding piece during a move animation.
                // Same pattern as layer 2: only rendered while an animation
                // is genuinely in flight, otherwise the call site is gone.
                if game.scrubIndex == nil,
                   let mv = game.animatingMove,
                   moveSlideProgress < 1.0,
                   let movingPiece = displayBoard.piece(at: mv.to) {
                    animatingPiece(piece: movingPiece, move: mv, cellSide: cellSide)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                        .allowsHitTesting(false)
                }

                // Coordinate labels (a..h along bottom, 1..8 along left).
                coordinateLabels(cellSide: cellSide, palette: palette)
            }
            .onChange(of: game.totalPlies) { _, _ in
                triggerSlideAnimation()
            }
        }
        .aspectRatio(1.0, contentMode: .fit)
    }

    /// Map a display position (row, col with origin top-left) to the
    /// algebraic square index. Encapsulates the board-orientation flip when
    /// the human plays Black.
    private func squareForDisplayRowCol(row: Int, col: Int) -> Int {
        let rank: Int
        let file: Int
        if game.playerIsWhite {
            rank = 7 - row
            file = col
        } else {
            rank = row
            file = 7 - col
        }
        return Square.make(file: file, rank: rank)
    }

    /// Resets `moveSlideProgress` to 0 and animates it to 1 with a spring.
    /// The piece view reads `moveSlideProgress` to interpolate its offset.
    private func triggerSlideAnimation() {
        moveSlideProgress = 0.0
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            moveSlideProgress = 1.0
        }
    }

    /// Background + highlight + piece layer for a single square. The piece
    /// is rendered *inside* the square so the entire cell — bg, highlight,
    /// and the silhouette on top — is one composable layout box. This is
    /// what makes tap handling work reliably on Skip's Compose backend;
    /// when pieces lived in a separate offset-positioned overlay layer,
    /// Android touch dispatch silently broke after the first move because
    /// the offset overlay's allowsHitTesting(false) doesn't propagate the
    /// same way it does in SwiftUI.
    ///
    /// The destination square of an in-flight slide animation suppresses
    /// its piece — the sliding overlay (`animatingPiece`) draws that
    /// piece in motion above the board until the spring settles.
    private func squareBackgroundView(sq: Int, cellSide: Double, displayBoard: Board,
                                      lastFrom: Int, lastTo: Int,
                                      palette: ChessBoardPalette) -> some View {
        let file = Square.file(sq)
        let rank = Square.rank(sq)
        let isLight = (file + rank) % 2 == 1
        let bg = isLight ? palette.lightSquare : palette.darkSquare
        let isSelected = game.selectedSquare == sq
        let isLastMove = (sq == lastFrom) || (sq == lastTo)
        let isLegalDestination = highlightLegalMoves && containsDestination(sq: sq)
        let isCheckSquare = isCheckedKingSquare(sq: sq, board: displayBoard)
        // Suppress the piece while it's mid-slide so the overlay can own it.
        let isAnimatingDestination: Bool = (game.scrubIndex == nil)
            && (game.animatingMove?.to == sq)
            && (moveSlideProgress < 1.0)
        let piece: Piece? = displayBoard.piece(at: sq)

        return ZStack {
            Rectangle()
                .fill(bg)
                .frame(width: cellSide, height: cellSide)
            if isLastMove {
                Rectangle()
                    .fill(palette.lastMoveHighlight)
                    .frame(width: cellSide, height: cellSide)
            }
            if isCheckSquare {
                Rectangle()
                    .fill(palette.checkHighlight.opacity(0.55))
                    .frame(width: cellSide, height: cellSide)
            }
            if isSelected {
                Rectangle()
                    .stroke(palette.selectionHalo, lineWidth: 3)
                    .frame(width: cellSide - 1, height: cellSide - 1)
            }
            if let p = piece, !isAnimatingDestination {
                ChessPieceView(piece: p, theme: theme)
                    .frame(width: cellSide * 0.94, height: cellSide * 0.94)
                    .allowsHitTesting(false)
            }
            if isLegalDestination {
                Circle()
                    .fill(palette.legalMoveDot.opacity(0.55))
                    .frame(width: cellSide * 0.28, height: cellSide * 0.28)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: cellSide, height: cellSide)
        .onTapGesture {
            onSquareTap(sq)
        }
        .accessibilityIdentifier("square.\(Square.name(sq))")
    }

    /// Single sliding piece drawn on top of the board during a move
    /// animation. The caller guards on `animatingMove` and on the slide
    /// progress, and applies `.allowsHitTesting(false)` at the call site
    /// — keeping the conditional out of this builder is what stops Skip's
    /// Compose backend from leaving an invisible touch-sink Box behind
    /// when the animation isn't in flight.
    private func animatingPiece(piece: Piece, move: Move, cellSide: Double) -> some View {
        let srcFile = Square.file(move.from)
        let srcRank = Square.rank(move.from)
        let dstFile = Square.file(move.to)
        let dstRank = Square.rank(move.to)
        let srcRow: Int = game.playerIsWhite ? (7 - srcRank) : srcRank
        let srcCol: Int = game.playerIsWhite ? srcFile : (7 - srcFile)
        let dstRow: Int = game.playerIsWhite ? (7 - dstRank) : dstRank
        let dstCol: Int = game.playerIsWhite ? dstFile : (7 - dstFile)
        let t: Double = moveSlideProgress
        let cellSide_d: Double = cellSide
        let originX: Double = Double(srcCol) * cellSide_d + (Double(dstCol - srcCol) * cellSide_d * t)
        let originY: Double = Double(srcRow) * cellSide_d + (Double(dstRow - srcRow) * cellSide_d * t)
        let pieceInset: Double = cellSide_d * 0.03
        return ZStack(alignment: .topLeading) {
            ChessPieceView(piece: piece, theme: theme)
                .frame(width: cellSide * 0.94, height: cellSide * 0.94)
                .offset(x: originX + pieceInset, y: originY + pieceInset)
        }
    }

    /// Returns the centre point of a board square in the board's local
    /// coordinate space.
    private func squareCenter(sq: Int, cellSide: Double) -> CGPoint {
        let file = Square.file(sq)
        let rank = Square.rank(sq)
        let row = game.playerIsWhite ? (7 - rank) : rank
        let col = game.playerIsWhite ? file : (7 - file)
        return CGPoint(
            x: (Double(col) + 0.5) * cellSide,
            y: (Double(row) + 0.5) * cellSide
        )
    }

    /// Renders each side's most recent move as a faint thick arrow tinted
    /// with that side's piece colour. Arrows are suppressed when:
    ///   - no move has been played yet for that side, or
    ///   - the piece that did the move is no longer on its destination
    ///     square (e.g. the opponent captured it on the next move).
    private func arrowsLayer(cellSide: Double) -> some View {
        let palette = theme.palette
        let liveBoard = game.game.board
        // White's arrow is shown only if a white piece still sits on
        // lastWhiteMoveTo. Same check for black on the other side.
        let showWhiteArrow: Bool
        if game.lastWhiteMoveFrom >= 0 && game.lastWhiteMoveTo >= 0,
           let p = liveBoard.piece(at: game.lastWhiteMoveTo),
           p.color == PieceColor.white {
            showWhiteArrow = true
        } else {
            showWhiteArrow = false
        }
        let showBlackArrow: Bool
        if game.lastBlackMoveFrom >= 0 && game.lastBlackMoveTo >= 0,
           let p = liveBoard.piece(at: game.lastBlackMoveTo),
           p.color == PieceColor.black {
            showBlackArrow = true
        } else {
            showBlackArrow = false
        }
        return ZStack {
            if showWhiteArrow {
                arrowPath(
                    from: squareCenter(sq: game.lastWhiteMoveFrom, cellSide: cellSide),
                    to: squareCenter(sq: game.lastWhiteMoveTo, cellSide: cellSide),
                    cellSide: cellSide
                )
                .fill(palette.whitePiece.opacity(0.55))
            }
            if showBlackArrow {
                arrowPath(
                    from: squareCenter(sq: game.lastBlackMoveFrom, cellSide: cellSide),
                    to: squareCenter(sq: game.lastBlackMoveTo, cellSide: cellSide),
                    cellSide: cellSide
                )
                .fill(palette.blackPiece.opacity(0.55))
            }
        }
    }

    /// Build the closed path of a thick chess-style arrow from `src` to
    /// `dst`. The shaft is a uniform-width rectangle; the head is a wider
    /// triangle that bites into the destination square. Knights' L-shaped
    /// moves are drawn as a straight line, which is the standard chess
    /// arrow convention.
    private func arrowPath(from src: CGPoint, to dst: CGPoint, cellSide: Double) -> Path {
        // Skip's Kotlin transpiler is fussy about CGFloat/Double operator
        // overloads, so do all the geometry in plain Doubles and only
        // convert to CGPoint at the final addLine() calls.
        let sx: Double = Double(src.x)
        let sy: Double = Double(src.y)
        let dxd: Double = Double(dst.x) - sx
        let dyd: Double = Double(dst.y) - sy
        let len: Double = sqrt(dxd * dxd + dyd * dyd)
        if len < 1.0 { return Path() }
        let ux: Double = dxd / len
        let uy: Double = dyd / len
        // Perpendicular unit vector (rotate 90° CCW).
        let nx: Double = -uy
        let ny: Double = ux

        let shaftWidth: Double = cellSide * 0.22
        let headWidth: Double = cellSide * 0.46
        let headLength: Double = cellSide * 0.32
        // Start the shaft slightly out from the source-square centre so the
        // arrow doesn't bury its tail under the moving piece.
        let tailInset: Double = cellSide * 0.12
        // Stop the tip well short of the destination centre so the arrow
        // points AT the piece rather than disappearing behind it. ~0.32 of
        // a cell puts the tip near the edge of the destination piece's
        // silhouette, leaving the head clearly visible.
        let tipInset: Double = cellSide * 0.32
        let tailX: Double = sx + ux * tailInset
        let tailY: Double = sy + uy * tailInset
        let tipX: Double = Double(dst.x) - ux * tipInset
        let tipY: Double = Double(dst.y) - uy * tipInset
        let shaftEndX: Double = tipX - ux * headLength
        let shaftEndY: Double = tipY - uy * headLength

        let sw: Double = shaftWidth / 2.0
        let hw: Double = headWidth / 2.0

        return Path { p in
            p.move(to: CGPoint(x: tailX + nx * sw, y: tailY + ny * sw))
            p.addLine(to: CGPoint(x: shaftEndX + nx * sw, y: shaftEndY + ny * sw))
            p.addLine(to: CGPoint(x: shaftEndX + nx * hw, y: shaftEndY + ny * hw))
            p.addLine(to: CGPoint(x: tipX, y: tipY))
            p.addLine(to: CGPoint(x: shaftEndX - nx * hw, y: shaftEndY - ny * hw))
            p.addLine(to: CGPoint(x: shaftEndX - nx * sw, y: shaftEndY - ny * sw))
            p.addLine(to: CGPoint(x: tailX - nx * sw, y: tailY - ny * sw))
            p.closeSubpath()
        }
    }

    private func containsDestination(sq: Int) -> Bool {
        for m in game.selectedLegalMoves {
            if m.to == sq { return true }
        }
        return false
    }

    private func isCheckedKingSquare(sq: Int, board: Board) -> Bool {
        if !board.isCheck() { return false }
        guard let p = board.piece(at: sq) else { return false }
        if p.kind != PieceKind.king { return false }
        return p.color == board.sideToMove
    }

    private func coordinateLabels(cellSide: Double, palette: ChessBoardPalette) -> some View {
        ZStack(alignment: .topLeading) {
            // Files along the bottom row
            ForEach(0..<8, id: \.self) { col in
                let label = fileLabel(col: col)
                Text(label)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.labelColor)
                    .offset(x: Double(col) * cellSide + cellSide * 0.78,
                            y: 7.0 * cellSide + cellSide * 0.78)
                    .allowsHitTesting(false)
            }
            // Ranks along the left column
            ForEach(0..<8, id: \.self) { row in
                let label = rankLabel(row: row)
                Text(label)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.labelColor)
                    .offset(x: cellSide * 0.04,
                            y: Double(row) * cellSide + cellSide * 0.04)
                    .allowsHitTesting(false)
            }
        }
    }

    private func fileLabel(col: Int) -> String {
        let displayedFile = game.playerIsWhite ? col : (7 - col)
        let letters: [String] = ["a", "b", "c", "d", "e", "f", "g", "h"]
        return letters[displayedFile]
    }

    private func rankLabel(row: Int) -> String {
        let displayedRank = game.playerIsWhite ? (8 - row) : (row + 1)
        return "\(displayedRank)"
    }
}

// MARK: - Pause menu

struct ChessPauseMenuView: View {
    @Bindable var game: ChessGameState
    let onResume: () -> Void
    let onNewGame: () -> Void
    let onShowSettings: () -> Void
    let onShowInstructions: () -> Void
    let onResign: () -> Void
    let onQuit: () -> Void

    @Environment(ChessSettings.self) var settings: ChessSettings
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Text("Paused", bundle: .module, comment: "Chess pause menu title")
                        .font(.largeTitle)
                        .fontWeight(.black)
                        .foregroundStyle(Color.white)
                        .padding(.top, 12)

                    actionButton("Resume", tint: Color(red: 0.20, green: 0.70, blue: 0.40), idSuffix: "resume", action: onResume)
                    actionButton("Settings", tint: Color(red: 0.35, green: 0.40, blue: 0.65), idSuffix: "settings", action: onShowSettings)
                    actionButton("How to Play", tint: Color(red: 0.30, green: 0.50, blue: 0.80), idSuffix: "howToPlay", action: onShowInstructions)

                    Divider().background(Color.white.opacity(0.2)).padding(.vertical, 6)

                    // Save / Share
                    Button(action: {
                        writeSavedState(game.makeSavedState())
                    }) {
                        Text("Save Game", bundle: .module, comment: "Chess pause menu: save the game so it survives an app relaunch")
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("button.pause.saveGame")

                    ShareLink(
                        item: game.game.currentFEN(),
                        subject: Text("Chess Position (FEN)", bundle: .module, comment: "Chess pause menu: share-sheet subject for FEN export"),
                        message: Text("Chess position from Faire Games", bundle: .module, comment: "Chess pause menu: share-sheet body for FEN export")
                    ) {
                        Label {
                            Text("Share FEN", bundle: .module, comment: "Chess pause menu: share the current position as FEN")
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                        } icon: {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("button.pause.shareFEN")

                    ShareLink(
                        item: makePGN(game: game),
                        subject: Text("Chess Game (PGN)", bundle: .module, comment: "Chess pause menu: share-sheet subject for PGN export"),
                        message: Text("Chess game from Faire Games", bundle: .module, comment: "Chess pause menu: share-sheet body for PGN export")
                    ) {
                        Label {
                            Text("Share Game (PGN)", bundle: .module, comment: "Chess pause menu: share the full game as PGN")
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                        } icon: {
                            Image(systemName: "square.and.arrow.up.on.square")
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("button.pause.sharePGN")

                    Divider().background(Color.white.opacity(0.2)).padding(.vertical, 6)

                    actionButton("Resign", tint: Color(red: 0.80, green: 0.35, blue: 0.35), idSuffix: "resign", action: onResign)
                    actionButton("New Game", tint: Color(red: 0.55, green: 0.40, blue: 0.95), idSuffix: "newGame", action: onNewGame)
                    actionButton("Quit Game", tint: Color(red: 0.85, green: 0.30, blue: 0.30), idSuffix: "quit", action: onQuit)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(settings.theme.palette.pageBackground.ignoresSafeArea())
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Text("Done", bundle: .module, comment: "Chess pause menu: dismiss the menu")
                            .foregroundStyle(Color.white)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func actionButton(_ key: String, tint: Color, idSuffix: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(key), bundle: .module)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .accessibilityIdentifier("button.pause.\(idSuffix)")
    }
}

// MARK: - PGN export

/// Build a minimal-but-correct PGN string from a `ChessGameState`. Includes
/// the standard seven-tag roster, a Result tag, and SAN moves separated by
/// move numbers. SAN is approximated from UCI + the position at each ply.
@MainActor
func makePGN(game: ChessGameState) -> String {
    var lines: [String] = []
    lines.append("[Event \"Faire Games Chess\"]")
    lines.append("[Site \"Faire Games\"]")
    lines.append("[Date \"-\"]")
    lines.append("[Round \"-\"]")
    let whiteName = game.playerIsWhite ? "Player" : "Engine"
    let blackName = game.playerIsWhite ? "Engine" : "Player"
    lines.append("[White \"\(whiteName)\"]")
    lines.append("[Black \"\(blackName)\"]")
    lines.append("[Result \"\(pgnResult(game.outcome))\"]")
    lines.append("")
    // Moves
    guard let board = FEN.parse(game.game.initialFEN) else {
        return lines.joined(separator: "\n")
    }
    var movetext: [String] = []
    var moveNum: Int = 1
    var isWhiteMove: Bool = (board.sideToMove == PieceColor.white)
    for mv in game.game.moveHistory {
        let san = toSAN(move: mv, on: board)
        _ = board.makeMove(mv)
        if isWhiteMove {
            movetext.append("\(moveNum). \(san)")
        } else {
            movetext.append(san)
            moveNum = moveNum + 1
        }
        isWhiteMove = !isWhiteMove
    }
    movetext.append(pgnResult(game.outcome))
    lines.append(movetext.joined(separator: " "))
    return lines.joined(separator: "\n")
}

private func pgnResult(_ outcome: ChessOutcome) -> String {
    switch outcome {
    case .whiteWinsByCheckmate, .whiteWinsByTimeout, .blackResigns:
        return "1-0"
    case .blackWinsByCheckmate, .blackWinsByTimeout, .whiteResigns:
        return "0-1"
    case .drawByStalemate, .drawByInsufficientMaterial,
         .drawByFiftyMoveRule, .drawByThreefoldRepetition, .drawByAgreement:
        return "1/2-1/2"
    case .ongoing:
        return "*"
    }
}

/// Best-effort SAN conversion. Handles plain moves, captures, castling, and
/// promotion. Doesn't fully disambiguate when two same-kind pieces can move
/// to the same square (rare) — falls back to the file disambiguator.
private func toSAN(move: Move, on board: Board) -> String {
    guard let piece = board.piece(at: move.from) else { return move.uci }
    // Castling.
    if piece.kind == PieceKind.king {
        let fromCol = Square.file(move.from)
        let toCol = Square.file(move.to)
        if abs(fromCol - toCol) == 2 {
            return toCol > fromCol ? "O-O" : "O-O-O"
        }
    }
    var s = ""
    let isCapture = (board.pieceCode(at: move.to) != 0) ||
        (piece.kind == PieceKind.pawn && Square.file(move.from) != Square.file(move.to))
    if piece.kind == PieceKind.pawn {
        if isCapture {
            s = s + fileLetter(Square.file(move.from)) + "x"
        }
        s = s + Square.name(move.to)
        if move.isPromotion, let promo = move.promotionKind {
            s = s + "=" + promo.letter.uppercased()
        }
    } else {
        s = s + piece.kind.letter.uppercased()
        // Disambiguation: if another same-kind same-color piece can also
        // move to `move.to`, include the file letter.
        if hasAmbiguousSource(move: move, piece: piece, board: board) {
            s = s + fileLetter(Square.file(move.from))
        }
        if isCapture { s = s + "x" }
        s = s + Square.name(move.to)
    }
    return s
}

private func hasAmbiguousSource(move: Move, piece: Piece, board: Board) -> Bool {
    var count = 0
    for m in board.legalMoves() {
        if m.to == move.to,
           let p = board.piece(at: m.from),
           p.kind == piece.kind, p.color == piece.color {
            count = count + 1
            if count >= 2 { return true }
        }
    }
    return false
}

private func fileLetter(_ file: Int) -> String {
    let letters: [String] = ["a", "b", "c", "d", "e", "f", "g", "h"]
    return letters[max(0, min(file, 7))]
}

// MARK: - Settings view

struct ChessSettingsView: View {
    @Bindable var settings: ChessSettings
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Feedback", bundle: .module, comment: "Chess settings section: haptic feedback toggles")) {
                    Toggle(isOn: $settings.vibrations) {
                        Text("Vibrations", bundle: .module, comment: "Chess settings: master haptic toggle")
                    }
                    .accessibilityIdentifier("toggle.vibrations")
                    Toggle(isOn: $settings.highlightLegalMoves) {
                        Text("Highlight Legal Moves", bundle: .module, comment: "Chess settings: show legal-move dots when a piece is selected")
                    }
                    .accessibilityIdentifier("toggle.highlightLegalMoves")
                    Toggle(isOn: $settings.showLastMoveArrows) {
                        Text("Show Last Move Arrows", bundle: .module, comment: "Chess settings: draw faint arrows showing each side's most recent move")
                    }
                    .accessibilityIdentifier("toggle.showLastMoveArrows")
                    Toggle(isOn: $settings.allowUndo) {
                        Text("Allow Undo from History Slider", bundle: .module, comment: "Chess settings: lifting the finger off a past slider position commits the undo")
                    }
                    .accessibilityIdentifier("toggle.allowUndo")
                }
                Section(header: Text("Theme", bundle: .module, comment: "Chess settings section: visual theme picker")) {
                    ForEach(ChessTheme.allCases) { t in
                        Button(action: { settings.theme = t }) {
                            HStack {
                                t.label
                                    .foregroundStyle(Color.primary)
                                Spacer()
                                if t == settings.theme {
                                    ChessCheckmark(color: Color.accentColor)
                                        .frame(width: 18, height: 14)
                                }
                            }
                        }
                        .accessibilityIdentifier("button.settings.theme.\(t.rawValue)")
                    }
                }
            }
            .navigationTitle(Text("Settings", bundle: .module, comment: "Chess settings sheet navigation title"))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: { dismiss() }) {
                        Text("Done", bundle: .module, comment: "Chess settings: dismiss the sheet")
                    }
                }
            }
        }
    }
}

// MARK: - Promotion picker

/// Sheet that prompts the player to pick a piece kind for an in-flight pawn
/// promotion. Renders four cards (queen, rook, bishop, knight) drawn in the
/// active theme so the choice feels in-world.
struct ChessPromotionPickerView: View {
    let pieceColor: PieceColor
    let theme: ChessTheme
    let onPick: (PieceKind) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Promote Pawn To", bundle: .module, comment: "Chess promotion picker: heading above the four piece choices")
                .font(.title3)
                .fontWeight(.heavy)
                .foregroundStyle(Color.white)
                .padding(.top, 18)
            HStack(spacing: 12) {
                promoCard(kind: PieceKind.queen)
                promoCard(kind: PieceKind.rook)
                promoCard(kind: PieceKind.bishop)
                promoCard(kind: PieceKind.knight)
            }
            .padding(.horizontal, 14)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.pageBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func promoCard(kind: PieceKind) -> some View {
        Button(action: {
            onPick(kind)
            dismiss()
        }) {
            VStack(spacing: 6) {
                ChessPieceView(piece: Piece(color: pieceColor, kind: kind), theme: theme)
                    .frame(width: 56, height: 56)
                kindNameText(kind)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.white)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.10)))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.25), lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("button.promote.\(kind.rawValue)")
    }

    @MainActor
    private func kindNameText(_ kind: PieceKind) -> Text {
        switch kind {
        case .queen:
            return Text("Queen", bundle: .module, comment: "Chess piece name: queen, used in promotion picker labels")
        case .rook:
            return Text("Rook", bundle: .module, comment: "Chess piece name: rook")
        case .bishop:
            return Text("Bishop", bundle: .module, comment: "Chess piece name: bishop")
        case .knight:
            return Text("Knight", bundle: .module, comment: "Chess piece name: knight")
        case .pawn:
            return Text("Pawn", bundle: .module, comment: "Chess piece name: pawn")
        case .king:
            return Text("King", bundle: .module, comment: "Chess piece name: king")
        }
    }
}

// MARK: - Preview icon

/// Tile shown on the FaireGames home grid. A mini board with a few pieces
/// in the player's currently-selected theme.
public struct ChessPreviewIcon: View {
    public init() { }

    public var body: some View {
        GeometryReader { geo in
            let palette = ChessTheme.classic.palette
            let cells: Int = 5
            let cellSide: Double = min(geo.size.width, geo.size.height) / Double(cells)
            ZStack {
                // Background board
                VStack(spacing: 0) {
                    ForEach(0..<cells, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<cells, id: \.self) { col in
                                Rectangle()
                                    .fill((row + col) % 2 == 0 ? palette.lightSquare : palette.darkSquare)
                                    .frame(width: cellSide, height: cellSide)
                            }
                        }
                    }
                }
                // Three pieces arranged in the lower-right corner.
                ChessPieceView(piece: Piece(color: PieceColor.white, kind: PieceKind.king), theme: ChessTheme.classic)
                    .frame(width: cellSide, height: cellSide)
                    .offset(x: cellSide * 1.5, y: cellSide * 1.5)
                ChessPieceView(piece: Piece(color: PieceColor.black, kind: PieceKind.knight), theme: ChessTheme.classic)
                    .frame(width: cellSide, height: cellSide)
                    .offset(x: -cellSide * 1.5, y: -cellSide * 0.5)
                ChessPieceView(piece: Piece(color: PieceColor.white, kind: PieceKind.pawn), theme: ChessTheme.classic)
                    .frame(width: cellSide, height: cellSide)
                    .offset(x: cellSide * 0.5, y: -cellSide * 1.5)
            }
        }
        .aspectRatio(1.0, contentMode: .fit)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.22))
        )
    }
}


// MARK: - Portable icons

/// A solid-coloured circle with a white checkmark inside. Used in place of
/// SF Symbol `checkmark.circle.fill` so the glyph renders identically on
/// Android (where SF Symbols often don't resolve).
struct ChessCheckCircle: View {
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(color)
                ChessCheckmark(color: Color.white)
                    .frame(width: s * 0.55, height: s * 0.40)
            }
        }
    }
}

/// A standalone checkmark path. Used where a checkmark is needed without a
/// circle background (e.g. settings rows).
struct ChessCheckmark: View {
    let color: Color
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width
                let h = geo.size.height
                p.move(to: CGPoint(x: w * 0.10, y: h * 0.55))
                p.addLine(to: CGPoint(x: w * 0.40, y: h * 0.88))
                p.addLine(to: CGPoint(x: w * 0.92, y: h * 0.20))
            }
            .stroke(color, style: StrokeStyle(lineWidth: max(2.0, geo.size.height * 0.18), lineCap: .round, lineJoin: .round))
        }
    }
}
