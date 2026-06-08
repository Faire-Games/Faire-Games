// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import OSLog
import Foundation
import SkipChess
import SkipChessModel
import SkipChessEngine
import SkipChessEngineAlphaBeta
@testable import Chess

let logger: Logger = Logger(subsystem: "Chess", category: "Tests")

@Suite struct ChessTests {

    @Test func chess() throws {
        logger.log("running testChess")
        #expect(1 + 2 == 3, "basic test")
    }

    @Test func decodeType() throws {
        let resourceURL: URL = try #require(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        #expect(testData.testModuleName == "Chess")
    }

    @Test func difficultyParametersAreSensible() throws {
        let easy = ChessDifficulty.easy
        let medium = ChessDifficulty.medium
        let hard = ChessDifficulty.hard
        // Hard searches deeper than medium, which searches deeper than easy.
        #expect(hard.searchDepth > medium.searchDepth)
        #expect(medium.searchDepth > easy.searchDepth)
        // Hard has more time budget than easy.
        #expect(hard.maxMilliseconds > easy.maxMilliseconds)
        // Hard reports a higher ELO than easy.
        #expect(hard.approximateElo > easy.approximateElo)
        // Hard never blunders deliberately; easy sometimes does.
        #expect(hard.blunderChance == 0.0)
        #expect(easy.blunderChance > 0.0)
    }

    @Test func savedStateRoundTrip() throws {
        let state = ChessSavedState(
            initialFEN: FEN.startingPositionFEN,
            moveUCIs: ["e2e4", "e7e5", "g1f3"],
            playerIsWhite: false,
            difficultyRaw: ChessDifficulty.hard.rawValue,
            timerStrategyRaw: ChessTimerStrategy.totalGame.rawValue,
            timerBudgetSeconds: 600,
            whiteElapsedSeconds: 42.5,
            blackElapsedSeconds: 17.0,
            loserOnTimeRaw: 0
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ChessSavedState.self, from: data)
        #expect(decoded == state)
        #expect(decoded.moveUCIs.count == 3)
        #expect(decoded.difficultyRaw == ChessDifficulty.hard.rawValue)
    }

    @Test func pieceValueScalesWithImportance() throws {
        #expect(ChessPieceValue.value(of: PieceKind.pawn) == 1)
        #expect(ChessPieceValue.value(of: PieceKind.knight) == 3)
        #expect(ChessPieceValue.value(of: PieceKind.bishop) == 3)
        #expect(ChessPieceValue.value(of: PieceKind.rook) == 5)
        #expect(ChessPieceValue.value(of: PieceKind.queen) == 9)
        // King doesn't get captured — value is 0 by convention.
        #expect(ChessPieceValue.value(of: PieceKind.king) == 0)
    }

    @Test func uciMoveParserAcceptsStartingMoves() throws {
        let board = Board.standardStartingPosition()
        let m = try #require(parseUCIMove("e2e4", on: board))
        #expect(m.from == Square.parse("e2"))
        #expect(m.to == Square.parse("e4"))
        #expect(m.promotion == 0)
    }

    @Test func uciMoveParserRejectsGarbage() throws {
        let board = Board.standardStartingPosition()
        #expect(parseUCIMove("zz9z", on: board) == nil)
        #expect(parseUCIMove("xyz", on: board) == nil)
        #expect(parseUCIMove("", on: board) == nil)
    }

    @Test func uciMoveParserAcceptsPromotion() throws {
        // Build a board where a white pawn on e7 can promote on e8. The
        // black king sits on a8 so the promotion target square is empty.
        // `try #require` instead of `Issue.record` because Skip's Kotlin
        // transpiler doesn't recognise the latter.
        let board = try #require(FEN.parse("k7/4P3/8/8/8/8/8/4K3 w - - 0 1"))
        let move = try #require(parseUCIMove("e7e8q", on: board))
        #expect(move.isPromotion)
        #expect(move.promotionKind == PieceKind.queen)
    }

    @Test func themePalettesProvideAllSlots() throws {
        // All five themes must produce a palette that's safe to use for
        // every named colour slot — no implicit-unwrap traps.
        for theme in ChessTheme.allCases {
            let palette = theme.palette
            // Just touching every slot is enough — the test fails if any
            // case branches in the palette computed property are missing.
            _ = palette.lightSquare
            _ = palette.darkSquare
            _ = palette.whitePiece
            _ = palette.blackPiece
            _ = palette.pieceOutline
            _ = palette.pageBackground
            _ = palette.panelBackground
            _ = palette.legalMoveDot
            _ = palette.selectionHalo
            _ = palette.checkHighlight
            _ = palette.lastMoveHighlight
            _ = palette.boardBorder
            _ = palette.labelColor
        }
    }

    @Test func themeMapsToPieceSet() throws {
        // Classic + Sunset + Neon use the cburnett piece set.
        #expect(ChessTheme.classic.pieceSet == ChessPieceSet.cburnett)
        #expect(ChessTheme.sunset.pieceSet == ChessPieceSet.cburnett)
        #expect(ChessTheme.neon.pieceSet == ChessPieceSet.cburnett)
        // Midnight + Forest use the merida piece set.
        #expect(ChessTheme.midnight.pieceSet == ChessPieceSet.merida)
        #expect(ChessTheme.forest.pieceSet == ChessPieceSet.merida)
        // Asset-prefix naming follows the convention bundled in
        // Module.xcassets — keep this in sync if either prefix changes.
        #expect(ChessPieceSet.cburnett.assetPrefix == "piece_cburnett_")
        #expect(ChessPieceSet.merida.assetPrefix == "piece_merida_")
    }

    @Test func capturedPieceCodableRoundTrip() throws {
        let captured = CapturedPiece(
            color: PieceColor.black.rawValue,
            kind: PieceKind.queen.rawValue,
            capturedAtPly: 17
        )
        let data = try JSONEncoder().encode(captured)
        let decoded = try JSONDecoder().decode(CapturedPiece.self, from: data)
        #expect(decoded == captured)
        #expect(decoded.pieceColor == PieceColor.black)
        #expect(decoded.pieceKind == PieceKind.queen)
        #expect(decoded.pointValue == 9)
    }

    @MainActor
    @Test func gameStateStartsAtStandardPosition() throws {
        let state = ChessGameState()
        // The board should be a standard starting position with white to move.
        #expect(state.game.board.sideToMove == PieceColor.white)
        #expect(state.game.moveHistory.count == 0)
        #expect(state.outcome == ChessOutcome.ongoing)
        #expect(state.totalPlies == 0)
        #expect(state.isPlayerTurn == true)
    }

    @MainActor
    @Test func startNewGameAppliesConfiguration() throws {
        let state = ChessGameState()
        state.startNewGame(
            playerIsWhite: false,
            difficulty: ChessDifficulty.hard,
            timerStrategy: ChessTimerStrategy.perMove,
            timerBudgetSeconds: 30
        )
        #expect(state.playerIsWhite == false)
        #expect(state.difficulty == ChessDifficulty.hard)
        #expect(state.timerStrategy == ChessTimerStrategy.perMove)
        #expect(state.timerBudgetSeconds == 30)
        #expect(state.outcome == ChessOutcome.ongoing)
        #expect(state.totalPlies == 0)
        // It's white's turn — and the player is black — so isPlayerTurn is false.
        #expect(state.isPlayerTurn == false)
    }

    @MainActor
    @Test func attemptMoveAdvancesGameWhenLegal() throws {
        let state = ChessGameState()
        state.startNewGame(
            playerIsWhite: true,
            difficulty: ChessDifficulty.easy,
            timerStrategy: ChessTimerStrategy.off,
            timerBudgetSeconds: 0
        )
        // Cancel the engine search the game may have queued so it doesn't
        // race against our move.
        state.cancelEngineSearch()
        let from = Square.parse("e2")
        let to = Square.parse("e4")
        // Player picks up the e-pawn first.
        state.selectedSquare = from
        state.selectedLegalMoves = state.legalMovesFrom(from)
        let played = state.attemptMove(from: from, to: to)
        #expect(played == true)
        #expect(state.totalPlies == 1)
        #expect(state.lastMoveFrom == from)
        #expect(state.lastMoveTo == to)
        state.cancelEngineSearch()
    }

    @MainActor
    @Test func resignEndsGameWithRightOutcome() throws {
        let state = ChessGameState()
        state.startNewGame(
            playerIsWhite: true,
            difficulty: ChessDifficulty.easy,
            timerStrategy: ChessTimerStrategy.off,
            timerBudgetSeconds: 0
        )
        state.cancelEngineSearch()
        state.resign()
        // Bind the boolean to a let before passing to #expect — Skip's
        // Kotlin transpiler mis-types the result of a ||-chained pair of
        // enum `==` comparisons when fed straight into the macro.
        let resigned: Bool = state.outcome == ChessOutcome.blackResigns
            || state.outcome == ChessOutcome.whiteResigns
        #expect(resigned)
        // White player resigning means black wins → outcome.blackResigns is
        // NOT what we want — "blackResigns" means *black* resigned. Verify
        // semantics: outcome is whichever maps to "white player gave up".
        #expect(state.outcome == ChessOutcome.blackResigns)
    }

    @MainActor
    @Test func makeAndRestoreSavedStateRoundTrips() throws {
        let state = ChessGameState()
        state.startNewGame(
            playerIsWhite: true,
            difficulty: ChessDifficulty.medium,
            timerStrategy: ChessTimerStrategy.totalGame,
            timerBudgetSeconds: 300
        )
        state.cancelEngineSearch()
        // Make a couple of moves so move history is non-empty.
        state.selectedSquare = Square.parse("e2")
        state.selectedLegalMoves = state.legalMovesFrom(Square.parse("e2"))
        _ = state.attemptMove(from: Square.parse("e2"), to: Square.parse("e4"))
        state.cancelEngineSearch()
        // Manually force the engine to NOT have moved — apply a known black
        // reply ourselves so the state is deterministic for the test.
        // Simulate black's move via direct board manipulation (bypassing
        // the engine).
        let blackMove = Move(from: Square.parse("e7"), to: Square.parse("e5"))
        _ = state.game.play(blackMove)
        state.whiteElapsedSeconds = 12.0
        state.blackElapsedSeconds = 7.5

        let saved = state.makeSavedState()
        #expect(saved.moveUCIs.count >= 2)
        #expect(saved.difficultyRaw == ChessDifficulty.medium.rawValue)
        #expect(saved.timerStrategyRaw == ChessTimerStrategy.totalGame.rawValue)

        // Restore into a fresh state.
        let restored = ChessGameState()
        let ok = restored.restore(saved)
        #expect(ok == true)
        #expect(restored.totalPlies == saved.moveUCIs.count)
        #expect(restored.difficulty == ChessDifficulty.medium)
        #expect(restored.timerStrategy == ChessTimerStrategy.totalGame)
        #expect(restored.whiteElapsedSeconds == 12.0)
        #expect(restored.blackElapsedSeconds == 7.5)
        restored.cancelEngineSearch()
    }

    @MainActor
    @Test func restoreRejectsCorruptedFEN() throws {
        let state = ChessGameState()
        let bad = ChessSavedState(
            initialFEN: "this is not a fen string",
            moveUCIs: [],
            playerIsWhite: true,
            difficultyRaw: 0,
            timerStrategyRaw: 0,
            timerBudgetSeconds: 0,
            whiteElapsedSeconds: 0,
            blackElapsedSeconds: 0,
            loserOnTimeRaw: 0
        )
        let ok = state.restore(bad)
        #expect(ok == false)
    }

    @MainActor
    @Test func pgnExportProducesValidStructure() throws {
        let state = ChessGameState()
        state.startNewGame(
            playerIsWhite: true,
            difficulty: ChessDifficulty.easy,
            timerStrategy: ChessTimerStrategy.off,
            timerBudgetSeconds: 0
        )
        state.cancelEngineSearch()
        // Apply a sequence of moves directly via the model to avoid engine races.
        let moves: [String] = ["e2e4", "e7e5", "g1f3", "b8c6"]
        for uci in moves {
            guard let m = parseUCIMove(uci, on: state.game.board) else { break }
            _ = state.game.play(m)
        }
        let pgn = makePGN(game: state)
        // PGN must contain the seven-tag roster headers (at minimum Event/Site/White/Black/Result).
        #expect(pgn.contains("[Event "))
        #expect(pgn.contains("[Site "))
        #expect(pgn.contains("[White "))
        #expect(pgn.contains("[Black "))
        #expect(pgn.contains("[Result "))
        // Move text should contain the standard SAN openings.
        #expect(pgn.contains("e4"))
        #expect(pgn.contains("e5"))
        #expect(pgn.contains("Nf3"))
        #expect(pgn.contains("Nc6"))
    }

}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
