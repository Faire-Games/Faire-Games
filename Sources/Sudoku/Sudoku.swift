// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import Observation
import SkipKit
import FaireGamesModel

public struct SudokuContainerView: View {
    @State private var settings = SudokuSettings()
    @State private var showInstructions: Bool = false
    private let instructionsConfig = GameInstructionsConfig(
        key: "Sudoku.instructions",
        bundle: .module,
        firstLaunchKey: "instructionsShown_Sudoku",
        title: "Sudoku"
    )

    public init() { }

    public var body: some View {
        SudokuGameView(showInstructions: $showInstructions)
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

public func resetSudokuRecords() {
    UserDefaults.standard.removeObject(forKey: "sudoku_best_easy")
    UserDefaults.standard.removeObject(forKey: "sudoku_best_medium")
    UserDefaults.standard.removeObject(forKey: "sudoku_best_hard")
    UserDefaults.standard.removeObject(forKey: "sudoku_best_expert")
    UserDefaults.standard.removeObject(forKey: "sudoku_puzzles_solved")
}

// MARK: - Difficulty

public enum SudokuDifficulty: Int, CaseIterable, Identifiable {
    case easy = 0
    case medium = 1
    case hard = 2
    case expert = 3

    public var id: Int { rawValue }

    var label: String {
        switch self {
        case .easy: return "Easy"
        case .medium: return "Medium"
        case .hard: return "Hard"
        case .expert: return "Expert"
        }
    }

    /// Number of clues (filled cells) to leave in the puzzle.
    var cluesCount: Int {
        switch self {
        case .easy: return 46
        case .medium: return 36
        case .hard: return 30
        case .expert: return 26
        }
    }

    var accentColor: Color {
        switch self {
        case .easy:   return Color(red: 0.35, green: 0.75, blue: 0.45)
        case .medium: return Color(red: 0.30, green: 0.60, blue: 0.95)
        case .hard:   return Color(red: 0.95, green: 0.55, blue: 0.15)
        case .expert: return Color(red: 0.90, green: 0.30, blue: 0.40)
        }
    }

    var bestTimeKey: String {
        switch self {
        case .easy: return "sudoku_best_easy"
        case .medium: return "sudoku_best_medium"
        case .hard: return "sudoku_best_hard"
        case .expert: return "sudoku_best_expert"
        }
    }

    /// Whether hints are available at this difficulty.
    var hintsEnabled: Bool {
        switch self {
        case .easy, .medium: return true
        case .hard, .expert: return false
        }
    }

    /// Easy mode grants unlimited hints; everything else is capped.
    var hasUnlimitedHints: Bool { self == .easy }

    /// Starting hint budget. `Int.max` is used as the unlimited sentinel for Easy.
    var initialHints: Int {
        switch self {
        case .easy: return Int.max
        case .medium: return 3
        case .hard, .expert: return 0
        }
    }

    /// Description shown in the difficulty picker.
    var detail: String {
        switch self {
        case .easy: return "\(cluesCount) clues \u{2022} unlimited hints"
        case .medium: return "\(cluesCount) clues \u{2022} 3 hints"
        case .hard: return "\(cluesCount) clues \u{2022} no hints"
        case .expert: return "\(cluesCount) clues \u{2022} no hints \u{2022} no same-number highlight"
        }
    }
}

// MARK: - Board Index Helpers

/// Cell index = row * 9 + col
@inline(__always) private func idx(_ row: Int, _ col: Int) -> Int { return row * 9 + col }

// MARK: - Puzzle Generator
//
// Strategy: start from a canonical valid solution and apply a series of
// structure-preserving random transformations (digit remap, row/col swaps
// within bands/stacks, band/stack swaps). The result is always a valid
// 9x9 Sudoku solution. We then remove cells symmetrically until we reach
// the target clue count for the given difficulty.

private let canonicalSolution: [Int] = [
    5, 3, 4,  6, 7, 8,  9, 1, 2,
    6, 7, 2,  1, 9, 5,  3, 4, 8,
    1, 9, 8,  3, 4, 2,  5, 6, 7,

    8, 5, 9,  7, 6, 1,  4, 2, 3,
    4, 2, 6,  8, 5, 3,  7, 9, 1,
    7, 1, 3,  9, 2, 4,  8, 5, 6,

    9, 6, 1,  5, 3, 7,  2, 8, 4,
    2, 8, 7,  4, 1, 9,  6, 3, 5,
    3, 4, 5,  2, 8, 6,  1, 7, 9
]

private func shuffleDigits(_ grid: inout [Int]) {
    // Random permutation of 1..9
    var perm = [1, 2, 3, 4, 5, 6, 7, 8, 9]
    perm.shuffle()
    let mapping: [Int] = [0] + perm // index 0 stays 0 (empty)
    for i in 0..<grid.count {
        grid[i] = mapping[grid[i]]
    }
}

private func swapRows(_ grid: inout [Int], _ r1: Int, _ r2: Int) {
    for c in 0..<9 {
        let tmp = grid[idx(r1, c)]
        grid[idx(r1, c)] = grid[idx(r2, c)]
        grid[idx(r2, c)] = tmp
    }
}

private func swapCols(_ grid: inout [Int], _ c1: Int, _ c2: Int) {
    for r in 0..<9 {
        let tmp = grid[idx(r, c1)]
        grid[idx(r, c1)] = grid[idx(r, c2)]
        grid[idx(r, c2)] = tmp
    }
}

private func swapBands(_ grid: inout [Int], _ b1: Int, _ b2: Int) {
    for i in 0..<3 {
        swapRows(&grid, b1 * 3 + i, b2 * 3 + i)
    }
}

private func swapStacks(_ grid: inout [Int], _ s1: Int, _ s2: Int) {
    for i in 0..<3 {
        swapCols(&grid, s1 * 3 + i, s2 * 3 + i)
    }
}

private func generateSolution() -> [Int] {
    var grid = canonicalSolution
    // Remap digits
    shuffleDigits(&grid)
    // Do several random transformations
    for _ in 0..<30 {
        let op = Int.random(in: 0...3)
        switch op {
        case 0:
            // Swap two rows in same band
            let band = Int.random(in: 0...2)
            var r1 = Int.random(in: 0...2)
            var r2 = Int.random(in: 0...2)
            while r1 == r2 { r2 = Int.random(in: 0...2) }
            swapRows(&grid, band * 3 + r1, band * 3 + r2)
            let _ = r1
        case 1:
            // Swap two cols in same stack
            let stack = Int.random(in: 0...2)
            var c1 = Int.random(in: 0...2)
            var c2 = Int.random(in: 0...2)
            while c1 == c2 { c2 = Int.random(in: 0...2) }
            swapCols(&grid, stack * 3 + c1, stack * 3 + c2)
            let _ = c1
        case 2:
            // Swap two bands
            var b1 = Int.random(in: 0...2)
            var b2 = Int.random(in: 0...2)
            while b1 == b2 { b2 = Int.random(in: 0...2) }
            swapBands(&grid, b1, b2)
        default:
            // Swap two stacks
            var s1 = Int.random(in: 0...2)
            var s2 = Int.random(in: 0...2)
            while s1 == s2 { s2 = Int.random(in: 0...2) }
            swapStacks(&grid, s1, s2)
        }
    }
    return grid
}

private func generatePuzzle(difficulty: SudokuDifficulty) -> (puzzle: [Int], solution: [Int]) {
    let solution = generateSolution()
    var puzzle = solution
    // Remove cells until we reach target clue count. Use symmetric pair removal
    // (remove cell and its 180-degree rotation mate) for visual appeal.
    let targetClues = difficulty.cluesCount
    var indices = Array(0..<81)
    indices.shuffle()
    var cluesRemaining = 81
    var i = 0
    while cluesRemaining > targetClues && i < indices.count {
        let cellIndex = indices[i]
        i += 1
        if puzzle[cellIndex] == 0 { continue }
        let mate = 80 - cellIndex // 180 rotation
        puzzle[cellIndex] = 0
        cluesRemaining -= 1
        if cellIndex != mate && puzzle[mate] != 0 && cluesRemaining > targetClues {
            puzzle[mate] = 0
            cluesRemaining -= 1
        }
    }
    return (puzzle, solution)
}

// MARK: - Saved State

struct SudokuSavedState: Codable {
    var values: [Int]
    var isOriginal: [Bool]
    var solution: [Int]
    var notes: [Int]
    var isProvisional: [Bool]
    var isFilledByGiveUp: [Bool]
    var difficultyRaw: Int
    var hintsRemaining: Int
    var elapsedSeconds: Int
    var isComplete: Bool
    var hasGivenUp: Bool
    var checkpointActive: Bool
    var checkpointValues: [Int]
    var checkpointNotes: [Int]
    var historyIndices: [Int]
    var historyOldValues: [Int]
    var historyOldNotes: [Int]
    var historyOldProvisional: [Bool]
    var historyNewValues: [Int]
    var historyNewNotes: [Int]
    var historyNewProvisional: [Bool]
    var historyCursor: Int
}

// MARK: - Game Model

@Observable
final class SudokuModel {
    // Board state — flat 81-element arrays for simple Skip-friendly mutation.
    var values: [Int] = Array(repeating: 0, count: 81)
    var isOriginal: [Bool] = Array(repeating: false, count: 81)
    var solution: [Int] = Array(repeating: 0, count: 81)
    /// Bitmask of candidate pencil marks per cell. Bit n (1-9) set means note n.
    var notes: [Int] = Array(repeating: 0, count: 81)
    /// Whether each cell's value was placed during the current checkpoint session.
    var isProvisional: [Bool] = Array(repeating: false, count: 81)
    /// Whether each cell's value was inserted by Give Up (vs. placed by the user).
    /// Used after `hasGivenUp` to tint auto-filled cells distinctly from user-placed ones.
    var isFilledByGiveUp: [Bool] = Array(repeating: false, count: 81)

    // Interaction state
    var selectedIndex: Int? = nil
    var notesMode: Bool = false

    // Checkpoint state
    var checkpointActive: Bool = false
    /// Snapshot of values taken when checkpoint mode was entered (for revert).
    var checkpointValues: [Int] = Array(repeating: 0, count: 81)
    var checkpointNotes: [Int] = Array(repeating: 0, count: 81)

    // Progress
    var difficulty: SudokuDifficulty = .medium
    var hintsRemaining: Int = 3
    var elapsedSeconds: Int = 0
    var isPaused: Bool = false
    var isComplete: Bool = false
    var hasGivenUp: Bool = false

    /// True when the game is finished and the board is locked (give-up only — no
    /// mistakes-based loss state exists). Kept as a computed alias of `hasGivenUp`
    /// so view conditionals read naturally.
    var isGameOver: Bool { hasGivenUp }

    // Records
    var bestEasy: Int = UserDefaults.standard.integer(forKey: "sudoku_best_easy")
    var bestMedium: Int = UserDefaults.standard.integer(forKey: "sudoku_best_medium")
    var bestHard: Int = UserDefaults.standard.integer(forKey: "sudoku_best_hard")
    var bestExpert: Int = UserDefaults.standard.integer(forKey: "sudoku_best_expert")
    var puzzlesSolved: Int = UserDefaults.standard.integer(forKey: "sudoku_puzzles_solved")

    // Cursor-based history (unlimited undo/redo).
    // history[0..<cursor] are undoable; history[cursor..<count] are redoable.
    var historyIndices: [Int] = []
    var historyOldValues: [Int] = []
    var historyOldNotes: [Int] = []
    var historyOldProvisional: [Bool] = []
    var historyNewValues: [Int] = []
    var historyNewNotes: [Int] = []
    var historyNewProvisional: [Bool] = []
    var historyCursor: Int = 0

    var canUndo: Bool { historyCursor > 0 }
    var canRedo: Bool { historyCursor < historyIndices.count }

    func bestTime(for difficulty: SudokuDifficulty) -> Int {
        switch difficulty {
        case .easy: return bestEasy
        case .medium: return bestMedium
        case .hard: return bestHard
        case .expert: return bestExpert
        }
    }

    func updateBestTime(_ seconds: Int, for difficulty: SudokuDifficulty) -> Bool {
        let current = bestTime(for: difficulty)
        guard current == 0 || seconds < current else { return false }
        switch difficulty {
        case .easy:   bestEasy = seconds
        case .medium: bestMedium = seconds
        case .hard:   bestHard = seconds
        case .expert: bestExpert = seconds
        }
        UserDefaults.standard.set(seconds, forKey: difficulty.bestTimeKey)
        return true
    }

    func newGame(difficulty: SudokuDifficulty) {
        self.difficulty = difficulty
        let (puzzle, sol) = generatePuzzle(difficulty: difficulty)
        values = puzzle
        solution = sol
        isOriginal = puzzle.map { $0 != 0 }
        notes = Array(repeating: 0, count: 81)
        isProvisional = Array(repeating: false, count: 81)
        isFilledByGiveUp = Array(repeating: false, count: 81)
        selectedIndex = nil
        notesMode = false
        checkpointActive = false
        checkpointValues = Array(repeating: 0, count: 81)
        checkpointNotes = Array(repeating: 0, count: 81)
        hintsRemaining = difficulty.initialHints
        elapsedSeconds = 0
        isPaused = false
        isComplete = false
        hasGivenUp = false
        clearHistory()
    }

    private func clearHistory() {
        historyIndices.removeAll()
        historyOldValues.removeAll()
        historyOldNotes.removeAll()
        historyOldProvisional.removeAll()
        historyNewValues.removeAll()
        historyNewNotes.removeAll()
        historyNewProvisional.removeAll()
        historyCursor = 0
    }

    // MARK: Cell queries

    /// Count of digit `d` placed anywhere on the board.
    func placedCount(of d: Int) -> Int {
        var count = 0
        for v in values {
            if v == d { count += 1 }
        }
        return count
    }

    func isPeer(_ a: Int, _ b: Int) -> Bool {
        if a == b { return false }
        let ra = a / 9, ca = a % 9
        let rb = b / 9, cb = b % 9
        if ra == rb { return true }
        if ca == cb { return true }
        if ra / 3 == rb / 3 && ca / 3 == cb / 3 { return true }
        return false
    }

    /// True when this cell holds a value that duplicates another value in the same
    /// row, column, or 3×3 box. Used by Easy mode to flag obviously-wrong placements.
    func hasConflict(at index: Int) -> Bool {
        let v = values[index]
        if v == 0 { return false }
        let row = index / 9
        let col = index % 9
        for c in 0..<9 {
            if c != col && values[idx(row, c)] == v { return true }
        }
        for r in 0..<9 {
            if r != row && values[idx(r, col)] == v { return true }
        }
        let boxRow = (row / 3) * 3
        let boxCol = (col / 3) * 3
        for r in boxRow..<(boxRow + 3) {
            for c in boxCol..<(boxCol + 3) {
                if (r != row || c != col) && values[idx(r, c)] == v { return true }
            }
        }
        return false
    }

    // MARK: Notes bitmask helpers

    func hasNote(_ cellIndex: Int, _ digit: Int) -> Bool {
        return (notes[cellIndex] & (1 << digit)) != 0
    }

    func toggleNote(_ cellIndex: Int, _ digit: Int) {
        notes[cellIndex] = notes[cellIndex] ^ (1 << digit)
    }

    func clearNotes(_ cellIndex: Int) {
        notes[cellIndex] = 0
    }

    /// Remove `digit` from the notes of all peers of `cellIndex`.
    func clearPeerNotes(of cellIndex: Int, digit: Int) {
        let row = cellIndex / 9
        let col = cellIndex % 9
        let mask = ~(1 << digit)
        for c in 0..<9 {
            let ri = idx(row, c)
            notes[ri] = notes[ri] & mask
        }
        for r in 0..<9 {
            let ci = idx(r, col)
            notes[ci] = notes[ci] & mask
        }
        let boxRow = (row / 3) * 3
        let boxCol = (col / 3) * 3
        for r in boxRow..<(boxRow + 3) {
            for c in boxCol..<(boxCol + 3) {
                let bi = idx(r, c)
                notes[bi] = notes[bi] & mask
            }
        }
    }

    // MARK: Actions

    /// Record a single-cell edit in the history, dropping any pending redo entries.
    /// Caller passes the pre-edit and post-edit (value, notes, provisional) state.
    private func recordHistory(_ cellIndex: Int,
                               oldValue: Int, oldNotes: Int, oldProvisional: Bool,
                               newValue: Int, newNotes: Int, newProvisional: Bool) {
        // Drop any redo entries past the cursor — they're invalidated by the new edit.
        // Skip Lite's Array doesn't expose removeSubrange, so we use a removeLast loop.
        while historyIndices.count > historyCursor {
            historyIndices.removeLast()
            historyOldValues.removeLast()
            historyOldNotes.removeLast()
            historyOldProvisional.removeLast()
            historyNewValues.removeLast()
            historyNewNotes.removeLast()
            historyNewProvisional.removeLast()
        }
        historyIndices.append(cellIndex)
        historyOldValues.append(oldValue)
        historyOldNotes.append(oldNotes)
        historyOldProvisional.append(oldProvisional)
        historyNewValues.append(newValue)
        historyNewNotes.append(newNotes)
        historyNewProvisional.append(newProvisional)
        historyCursor = historyIndices.count
    }

    /// Attempt to place `digit` into the selected cell. Returns true if a value change occurred.
    @discardableResult
    func placeDigit(_ digit: Int) -> Bool {
        guard let i = selectedIndex, !isPaused, !isComplete, !isGameOver else { return false }
        if isOriginal[i] { return false }
        let oldValue = values[i]
        let oldNotes = notes[i]
        let oldProvisional = isProvisional[i]
        if notesMode {
            toggleNote(i, digit)
            // A note edit is provisional iff we are in checkpoint mode and the
            // edit happens on a fresh (not previously-touched) cell, or the cell
            // is already provisional.
            if checkpointActive { isProvisional[i] = true }
            recordHistory(i,
                          oldValue: oldValue, oldNotes: oldNotes, oldProvisional: oldProvisional,
                          newValue: values[i], newNotes: notes[i], newProvisional: isProvisional[i])
            return true
        }
        // If the cell already has this digit, treat as clear.
        if values[i] == digit {
            values[i] = 0
            // Clearing a value also clears the provisional flag (cell is now empty).
            isProvisional[i] = false
            recordHistory(i,
                          oldValue: oldValue, oldNotes: oldNotes, oldProvisional: oldProvisional,
                          newValue: values[i], newNotes: notes[i], newProvisional: isProvisional[i])
            return true
        }
        values[i] = digit
        clearNotes(i)
        isProvisional[i] = checkpointActive
        if digit == solution[i] {
            // Correct placement: clear this digit from peer notes for convenience.
            clearPeerNotes(of: i, digit: digit)
        }
        recordHistory(i,
                      oldValue: oldValue, oldNotes: oldNotes, oldProvisional: oldProvisional,
                      newValue: values[i], newNotes: notes[i], newProvisional: isProvisional[i])
        checkCompletion()
        return true
    }

    func undo() {
        guard canUndo else { return }
        historyCursor -= 1
        let i = historyIndices[historyCursor]
        values[i] = historyOldValues[historyCursor]
        notes[i] = historyOldNotes[historyCursor]
        isProvisional[i] = historyOldProvisional[historyCursor]
    }

    func redo() {
        guard canRedo else { return }
        let i = historyIndices[historyCursor]
        values[i] = historyNewValues[historyCursor]
        notes[i] = historyNewNotes[historyCursor]
        isProvisional[i] = historyNewProvisional[historyCursor]
        historyCursor += 1
    }

    /// Whether a hint can be used right now — true when the difficulty grants
    /// unlimited hints (Easy) or there is at least one hint remaining.
    var canUseHint: Bool {
        if !difficulty.hintsEnabled { return false }
        if difficulty.hasUnlimitedHints { return true }
        return hintsRemaining > 0
    }

    /// Use a hint to auto-fill the correct value into the selected cell.
    /// If no cell is selected, picks the first empty cell.
    func useHint() {
        guard canUseHint, !isPaused, !isComplete, !isGameOver else { return }
        var target = selectedIndex
        if target == nil || (target != nil && (isOriginal[target!] || values[target!] == solution[target!])) {
            // Pick first empty or incorrect cell
            for i in 0..<81 {
                if !isOriginal[i] && values[i] != solution[i] {
                    target = i
                    break
                }
            }
        }
        guard let i = target else { return }
        if isOriginal[i] { return }
        let oldValue = values[i]
        let oldNotes = notes[i]
        let oldProvisional = isProvisional[i]
        values[i] = solution[i]
        notes[i] = 0
        // A hint placement is treated as committed even in checkpoint mode — the
        // user explicitly asked for the correct answer.
        isProvisional[i] = false
        if !difficulty.hasUnlimitedHints {
            hintsRemaining -= 1
        }
        selectedIndex = i
        clearPeerNotes(of: i, digit: solution[i])
        recordHistory(i,
                      oldValue: oldValue, oldNotes: oldNotes, oldProvisional: oldProvisional,
                      newValue: values[i], newNotes: notes[i], newProvisional: isProvisional[i])
        checkCompletion()
    }

    // MARK: Checkpoint

    /// Begin checkpoint mode: snapshot current values/notes so a revert can restore them.
    /// Any pending redo entries are dropped — moves you abandoned before opening the
    /// checkpoint shouldn't reappear once you commit or revert it.
    func enterCheckpoint() {
        guard !isPaused, !isComplete, !isGameOver, !checkpointActive else { return }
        while historyIndices.count > historyCursor {
            historyIndices.removeLast()
            historyOldValues.removeLast()
            historyOldNotes.removeLast()
            historyOldProvisional.removeLast()
            historyNewValues.removeLast()
            historyNewNotes.removeLast()
            historyNewProvisional.removeLast()
        }
        checkpointValues = values
        checkpointNotes = notes
        checkpointActive = true
    }

    /// Commit the checkpoint: keep all values, clear provisional flags. Clears history
    /// because committed values are now indistinguishable from any earlier ones.
    func commitCheckpoint() {
        guard checkpointActive else { return }
        isProvisional = Array(repeating: false, count: 81)
        checkpointActive = false
        clearHistory()
    }

    /// Revert the checkpoint: restore the snapshot taken when checkpoint mode began,
    /// removing every value/note placed during the session. Clears history.
    func revertCheckpoint() {
        guard checkpointActive else { return }
        values = checkpointValues
        notes = checkpointNotes
        isProvisional = Array(repeating: false, count: 81)
        checkpointActive = false
        clearHistory()
    }

    func checkCompletion() {
        for i in 0..<81 {
            if values[i] != solution[i] { return }
        }
        isComplete = true
        puzzlesSolved += 1
        UserDefaults.standard.set(puzzlesSolved, forKey: "sudoku_puzzles_solved")
        let _ = updateBestTime(elapsedSeconds, for: difficulty)
    }

    func giveUp() {
        // Fill all empty cells with the solution and mark them so the post-mortem
        // view can tint them distinctly from user-placed cells.
        for i in 0..<81 {
            if !isOriginal[i] && values[i] == 0 {
                values[i] = solution[i]
                isFilledByGiveUp[i] = true
            }
        }
        // Drop any checkpoint UI state — there's nothing left to revert to.
        checkpointActive = false
        isProvisional = Array(repeating: false, count: 81)
        hasGivenUp = true
        isPaused = false
    }

    func tick() {
        if isPaused || isComplete || isGameOver { return }
        elapsedSeconds += 1
    }

    // MARK: Persistence

    func makeSavedState() -> SudokuSavedState {
        return SudokuSavedState(
            values: values,
            isOriginal: isOriginal,
            solution: solution,
            notes: notes,
            isProvisional: isProvisional,
            isFilledByGiveUp: isFilledByGiveUp,
            difficultyRaw: difficulty.rawValue,
            hintsRemaining: hintsRemaining,
            elapsedSeconds: elapsedSeconds,
            isComplete: isComplete,
            hasGivenUp: hasGivenUp,
            checkpointActive: checkpointActive,
            checkpointValues: checkpointValues,
            checkpointNotes: checkpointNotes,
            historyIndices: historyIndices,
            historyOldValues: historyOldValues,
            historyOldNotes: historyOldNotes,
            historyOldProvisional: historyOldProvisional,
            historyNewValues: historyNewValues,
            historyNewNotes: historyNewNotes,
            historyNewProvisional: historyNewProvisional,
            historyCursor: historyCursor
        )
    }

    func restoreState(_ state: SudokuSavedState) {
        values = state.values
        isOriginal = state.isOriginal
        solution = state.solution
        notes = state.notes
        isProvisional = state.isProvisional
        isFilledByGiveUp = state.isFilledByGiveUp
        difficulty = SudokuDifficulty(rawValue: state.difficultyRaw) ?? .medium
        hintsRemaining = state.hintsRemaining
        elapsedSeconds = state.elapsedSeconds
        isComplete = state.isComplete
        hasGivenUp = state.hasGivenUp
        checkpointActive = state.checkpointActive
        checkpointValues = state.checkpointValues
        checkpointNotes = state.checkpointNotes
        historyIndices = state.historyIndices
        historyOldValues = state.historyOldValues
        historyOldNotes = state.historyOldNotes
        historyOldProvisional = state.historyOldProvisional
        historyNewValues = state.historyNewValues
        historyNewNotes = state.historyNewNotes
        historyNewProvisional = state.historyNewProvisional
        historyCursor = state.historyCursor
        selectedIndex = nil
        notesMode = false
        isPaused = false
    }

    func saveState() {
        guard let data = try? JSONEncoder().encode(makeSavedState()) else { return }
        guard let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: "sudoku_saved_state")
    }

    static func loadSavedState() -> SudokuSavedState? {
        guard let json = UserDefaults.standard.string(forKey: "sudoku_saved_state") else { return nil }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SudokuSavedState.self, from: data)
    }

    static func clearSavedState() {
        UserDefaults.standard.removeObject(forKey: "sudoku_saved_state")
    }
}

// MARK: - Game View

struct SudokuGameView: View {
    @Binding var showInstructions: Bool
    @State private var game = SudokuModel()
    @State private var timerTask: Task<Void, Never>? = nil
    @State private var showPauseMenu = false
    @State private var showSettings = false
    @State private var showDifficultyPicker = false
    @State private var hasInitialized = false
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase
    @Environment(SudokuSettings.self) var settings: SudokuSettings

    func playHaptic(_ pattern: HapticPattern) {
        if settings.vibrations {
            HapticFeedback.play(pattern)
        }
    }

    // MARK: Sudoku-specific haptic patterns

    /// Heavy press for placing a digit into a cell — the keycap moves from raised to
    /// lowered, so a thud reinforces the physical "click in."
    var pushInHaptic: HapticPattern {
        HapticPattern([HapticEvent(.thud, intensity: 0.55)])
    }

    /// Light release for clearing the same digit out of a cell — the keycap pops
    /// back up, so a low-tick + tick reads as a release.
    var depressHaptic: HapticPattern {
        HapticPattern([
            HapticEvent(.lowTick, intensity: 0.5),
            HapticEvent(.tick, intensity: 0.3, delay: 0.04)
        ])
    }

    /// Undo — feels like reversing direction, so the intensity falls.
    var undoHaptic: HapticPattern {
        HapticPattern([HapticEvent(.fall, intensity: 0.6)])
    }

    /// Redo — re-applying a move, so the intensity rises.
    var redoHaptic: HapticPattern {
        HapticPattern([HapticEvent(.rise, intensity: 0.6)])
    }

    /// Commit — celebratory confirmation when the player locks in a checkpoint.
    var commitHaptic: HapticPattern { .success }

    /// Revert — sad descending tones when the player throws their experiment away.
    var revertHaptic: HapticPattern { .error }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                hudView
                    .frame(height: 44)
                    .padding(.horizontal, 12.0)

                statusBar
                    .padding(.horizontal, 16.0)
                    .padding(.top, 6.0)

                Spacer(minLength: 8)

                // Board
                ZStack {
                    boardView(size: min(geo.size.width - 20.0, geo.size.height * 0.60))
                        .frame(width: min(geo.size.width - 20.0, geo.size.height * 0.60),
                               height: min(geo.size.width - 20.0, geo.size.height * 0.60))

                    if game.isPaused && !game.isComplete && !game.isGameOver {
                        pauseBoardCover(size: min(geo.size.width - 20.0, geo.size.height * 0.60))
                    }
                }

                Spacer(minLength: 8)

                controlPad
                    .padding(.horizontal, 12.0)
                    .padding(.top, 8.0)
                    .padding(.bottom, 12.0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.06, green: 0.07, blue: 0.14),
                             Color(red: 0.04, green: 0.04, blue: 0.10)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .overlay {
                if game.isComplete {
                    completeOverlay
                } else if showPauseMenu {
                    pauseMenuOverlay
                }
                // Give-up state intentionally has no overlay — the board reveals the
                // solution in-place, with red/green tints showing what went wrong and
                // what was auto-filled. The pause button remains available so the
                // player can start a new game or quit.
            }
        }
        .navigationBarBackButtonHidden()
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear {
            if !hasInitialized {
                hasInitialized = true
                if let savedState = SudokuModel.loadSavedState() {
                    game.restoreState(savedState)
                } else {
                    game.newGame(difficulty: settings.lastDifficulty)
                }
            }
            startTimer()
        }
        .onDisappear { stopTimer() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                pauseGame()
                game.saveState()
            }
        }
        .sheet(isPresented: $showSettings) {
            SudokuSettingsView(settings: settings)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showDifficultyPicker) {
            DifficultyPickerView(currentDifficulty: game.difficulty) { newDifficulty in
                settings.lastDifficulty = newDifficulty
                SudokuModel.clearSavedState()
                game.newGame(difficulty: newDifficulty)
                game.saveState()
                startTimer()
                showPauseMenu = false
                showDifficultyPicker = false
                playHaptic(.snap)
            }
        }
    }

    // MARK: HUD

    var hudView: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Image("cancel", bundle: .module)
                    .font(.title2)
                    .foregroundStyle(Color.white.opacity(0.7))
            }

            Spacer()

            Text("SUDOKU", bundle: .module)
                .font(.headline)
                .fontWeight(.heavy)
                .tracking(3)
                .foregroundStyle(Color.white.opacity(0.85))

            Spacer()

            Button(action: { pauseGame() }) {
                Image("pause_circle", bundle: .module)
                    .font(.title2)
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
    }

    var statusBar: some View {
        HStack(spacing: 0) {
            statusPill(title: "Difficulty", value: game.difficulty.label,
                       tint: game.difficulty.accentColor)
            Spacer(minLength: 8)
            statusPill(title: "Time", value: formatTime(game.elapsedSeconds),
                       tint: Color(red: 0.60, green: 0.75, blue: 0.95))
        }
    }

    func statusPill(title: String, value: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.55))
            Text(value)
                .font(.callout)
                .fontWeight(.bold)
                .foregroundStyle(tint)
                .monospaced()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6.0)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        }
    }

    // MARK: Board

    func boardView(size: Double) -> some View {
        let cellSize = size / 9.0
        let thinLine: Double = 0.5
        let thickLine: Double = 2.0
        return ZStack {
            // Background
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.10, green: 0.12, blue: 0.22))

            // Cells laid out in a standard 9x9 grid (no absolute positioning)
            // so that each cell has its own natural hit-testing area. Using
            // `.position()` here worked on iOS but broke tap detection on
            // Android, since Compose's tap handler covered the entire board
            // for every cell rather than just the cell's visible frame.
            VStack(spacing: 0) {
                ForEach(0..<9, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<9, id: \.self) { col in
                            let i = row * 9 + col
                            cellView(index: i, size: cellSize)
                                .onTapGesture {
                                    if game.isPaused || game.isComplete || game.isGameOver { return }
                                    game.selectedIndex = i
                                    playHaptic(.pick)
                                }
                        }
                    }
                }
            }

            // Grid lines overlay (drawn on top to not be occluded by cells)
            gridLinesOverlay(cellSize: cellSize, thin: thinLine, thick: thickLine)
                .allowsHitTesting(false)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.35), lineWidth: 2.0)
        }
    }

    func gridLinesOverlay(cellSize: Double, thin: Double, thick: Double) -> some View {
        ZStack(alignment: .topLeading) {
            // Thin horizontal lines
            ForEach(1..<9) { i in
                let isThick = (i % 3 == 0)
                Rectangle()
                    .fill(isThick
                          ? Color.white.opacity(0.55)
                          : Color.white.opacity(0.12))
                    .frame(height: isThick ? thick : thin)
                    .offset(y: Double(i) * cellSize - (isThick ? thick : thin) / 2.0)
            }
            // Thin vertical lines
            ForEach(1..<9) { i in
                let isThick = (i % 3 == 0)
                Rectangle()
                    .fill(isThick
                          ? Color.white.opacity(0.55)
                          : Color.white.opacity(0.12))
                    .frame(width: isThick ? thick : thin)
                    .offset(x: Double(i) * cellSize - (isThick ? thick : thin) / 2.0)
            }
        }
    }

    func cellView(index: Int, size: Double) -> some View {
        let value = game.values[index]
        let isSelected = game.selectedIndex == index
        let isOriginal = game.isOriginal[index]
        let isProvisional = game.isProvisional[index]
        let highlightLevel = computeHighlight(for: index)
        // After Give Up: tint auto-filled cells green, user's incorrect placements red.
        let isFilledByGiveUp = game.hasGivenUp && game.isFilledByGiveUp[index]
        let isUserWrong = game.hasGivenUp && !isOriginal && !isFilledByGiveUp
            && value != 0 && value != game.solution[index]
        // Easy mode flags obvious mistakes — a user-placed value that duplicates
        // a peer in its row, column, or box renders red even before Give Up.
        let isObviousMistake = !isOriginal && value != 0
            && game.difficulty == .easy && game.hasConflict(at: index)
        return ZStack {
            // Background
            Rectangle()
                .fill(cellBackground(isSelected: isSelected, highlight: highlightLevel))

            if value != 0 {
                Text("\(value)")
                    .font(.system(size: size * 0.55, weight: isOriginal ? .black : .semibold, design: .rounded))
                    .foregroundStyle(cellTextColor(isOriginal: isOriginal,
                                                   isProvisional: isProvisional,
                                                   isFilledByGiveUp: isFilledByGiveUp,
                                                   isUserWrong: isUserWrong,
                                                   isObviousMistake: isObviousMistake))
                    .monospaced()
            } else {
                notesGridView(index: index, cellSize: size, isProvisional: isProvisional)
            }
        }
        .frame(width: size, height: size)
    }

    func notesGridView(index: Int, cellSize: Double, isProvisional: Bool) -> some View {
        let noteFont = cellSize * 0.22
        let noteColor = isProvisional
            ? Color(red: 1.0, green: 0.78, blue: 0.40).opacity(0.85)
            : Color.white.opacity(0.55)
        return GeometryReader { _ in
            ZStack {
                ForEach(1..<10) { d in
                    let row = (d - 1) / 3
                    let col = (d - 1) % 3
                    if game.hasNote(index, d) {
                        Text("\(d)")
                            .font(.system(size: noteFont, weight: .medium, design: .rounded))
                            .foregroundStyle(noteColor)
                            .monospaced()
                            .position(
                                x: (Double(col) + 0.5) * (cellSize / 3.0),
                                y: (Double(row) + 0.5) * (cellSize / 3.0)
                            )
                    }
                }
            }
        }
        .frame(width: cellSize, height: cellSize)
    }

    /// Highlight levels: 0 = none, 1 = peer (row/col/box), 2 = same digit, 3 = selected.
    /// Expert mode suppresses the same-digit highlight to make the puzzle harder.
    func computeHighlight(for index: Int) -> Int {
        guard let sel = game.selectedIndex else { return 0 }
        if sel == index { return 3 }
        let selValue = game.values[sel]
        if game.difficulty != .expert && selValue != 0 && game.values[index] == selValue {
            return 2
        }
        if game.isPeer(sel, index) { return 1 }
        return 0
    }

    func cellBackground(isSelected: Bool, highlight: Int) -> Color {
        switch highlight {
        case 3:
            return Color(red: 0.25, green: 0.45, blue: 0.85).opacity(0.65)
        case 2:
            return Color(red: 0.20, green: 0.40, blue: 0.75).opacity(0.40)
        case 1:
            return Color(red: 0.14, green: 0.18, blue: 0.32).opacity(0.70)
        default:
            return Color(red: 0.08, green: 0.10, blue: 0.18)
        }
    }

    func cellTextColor(isOriginal: Bool, isProvisional: Bool,
                       isFilledByGiveUp: Bool, isUserWrong: Bool,
                       isObviousMistake: Bool) -> Color {
        if isFilledByGiveUp {
            // Auto-filled by Give Up — green so the player can spot what they hadn't found.
            return Color(red: 0.45, green: 0.92, blue: 0.55)
        }
        if isUserWrong || isObviousMistake {
            // Red flags wrong placements: revealed at the end by Give Up, or in
            // Easy mode whenever the value duplicates a peer.
            return Color(red: 1.0, green: 0.45, blue: 0.45)
        }
        if isOriginal {
            // Slightly dimmed so original clues read as immutable.
            return Color.white.opacity(0.62)
        }
        if isProvisional {
            // Distinctive amber/orange for values placed after a checkpoint.
            return Color(red: 1.0, green: 0.78, blue: 0.40)
        }
        return Color(red: 0.65, green: 0.85, blue: 1.0)
    }

    // MARK: Board Pause Cover

    func pauseBoardCover(size: Double) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.black.opacity(0.82))
            .frame(width: size, height: size)
            .overlay {
                VStack(spacing: 12) {
                    Image("pause_circle", bundle: .module)
                        .font(.system(size: 54))
                        .foregroundStyle(Color.white.opacity(0.75))
                    Text("PAUSED", bundle: .module)
                        .font(.title2)
                        .fontWeight(.heavy)
                        .tracking(4)
                        .foregroundStyle(Color.white.opacity(0.75))
                }
            }
    }

    // MARK: Control Pad (number grid + action buttons)

    var controlPad: some View {
        let busy = game.isPaused || game.isGameOver || game.isComplete
        // Pre-compute the Notes label as a Text view so the ternary is between Text
        // values (not String literals) — Skip Lite doesn't infer LocalizedStringKey
        // from a String? : String ternary.
        let notesLabel: Text = game.notesMode
            ? Text("Notes ✓", bundle: .module)
            : Text("Notes", bundle: .module)
        // Hint label varies: ∞ for unlimited (Easy), a count for Medium, just "Hint"
        // for difficulties with no hints (Hard/Expert).
        let hintLabel: Text
        if game.difficulty.hasUnlimitedHints {
            hintLabel = Text("Hint (∞)", bundle: .module)
        } else if !game.difficulty.hintsEnabled {
            hintLabel = Text("Hint", bundle: .module)
        } else {
            hintLabel = Text("Hint (\(game.hintsRemaining))", bundle: .module)
        }
        return HStack(spacing: 8) {
            // Left column: Notes (top), Hint (bottom)
            VStack(spacing: 8) {
                actionButton(label: notesLabel,
                             iconName: "edit",
                             highlighted: game.notesMode,
                             disabled: busy,
                             action: {
                                 game.notesMode.toggle()
                                 playHaptic(.pick)
                             })
                actionButton(label: hintLabel,
                             iconName: "lightbulb",
                             disabled: !game.canUseHint || busy,
                             action: {
                                 game.useHint()
                                 game.saveState()
                                 if game.isComplete {
                                     playHaptic(.bigCelebrate)
                                 } else {
                                     playHaptic(.snap)
                                 }
                             })
            }
            .frame(width: 64)

            // Center: 3x3 number grid
            numberPad

            // Right column: Undo/Redo (top), Checkpoint/Commit-Revert (bottom)
            VStack(spacing: 8) {
                undoOrUndoRedoButton(busy: busy)
                checkpointOrCommitRevertButton(busy: busy)
            }
            .frame(width: 64)
        }
    }

    @ViewBuilder
    func undoOrUndoRedoButton(busy: Bool) -> some View {
        if game.canRedo {
            splitActionButton(
                topLabel: Text("Undo", bundle: .module), topIcon: "undo",
                topDisabled: !game.canUndo || busy,
                topAction: {
                    game.undo()
                    game.saveState()
                    playHaptic(undoHaptic)
                },
                bottomLabel: Text("Redo", bundle: .module), bottomIcon: "redo",
                bottomDisabled: busy,
                bottomAction: {
                    game.redo()
                    game.saveState()
                    if game.isComplete {
                        playHaptic(.bigCelebrate)
                    } else {
                        playHaptic(redoHaptic)
                    }
                })
        } else {
            actionButton(label: Text("Undo", bundle: .module), iconName: "undo",
                         disabled: !game.canUndo || busy,
                         action: {
                             game.undo()
                             game.saveState()
                             playHaptic(undoHaptic)
                         })
        }
    }

    @ViewBuilder
    func checkpointOrCommitRevertButton(busy: Bool) -> some View {
        if game.checkpointActive {
            splitActionButton(
                topLabel: Text("Commit", bundle: .module), topIcon: "check",
                topDisabled: busy,
                topAction: {
                    game.commitCheckpoint()
                    game.saveState()
                    playHaptic(commitHaptic)
                },
                bottomLabel: Text("Revert", bundle: .module), bottomIcon: "close",
                bottomDisabled: busy,
                bottomAction: {
                    game.revertCheckpoint()
                    game.saveState()
                    playHaptic(revertHaptic)
                })
        } else {
            actionButton(label: Text("Checkpoint", bundle: .module), iconName: "flag",
                         disabled: busy,
                         action: {
                             game.enterCheckpoint()
                             game.saveState()
                             playHaptic(.pick)
                         })
        }
    }

    func actionButton(label: Text, iconName: String, highlighted: Bool = false, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(iconName, bundle: .module)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                label
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(highlighted ? Color.white : Color.white.opacity(disabled ? 0.35 : 0.80))
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(highlighted
                          ? Color(red: 0.30, green: 0.55, blue: 0.95).opacity(0.6)
                          : Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    /// Two stacked buttons sharing the same footprint as a single action button,
    /// separated by a thin horizontal divider.
    func splitActionButton(topLabel: Text, topIcon: String,
                           topDisabled: Bool, topAction: @escaping () -> Void,
                           bottomLabel: Text, bottomIcon: String,
                           bottomDisabled: Bool, bottomAction: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            splitHalf(label: topLabel, iconName: topIcon,
                      disabled: topDisabled, action: topAction)
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(height: 1)
            splitHalf(label: bottomLabel, iconName: bottomIcon,
                      disabled: bottomDisabled, action: bottomAction)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.06))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// One half of a vertically-split action button. Lays out the icon and label
    /// side-by-side to use the wider horizontal space in the half-height slot.
    private func splitHalf(label: Text, iconName: String,
                           disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(iconName, bundle: .module)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 13, height: 13)
                label
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(Color.white.opacity(disabled ? 0.35 : 0.80))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: Number Pad

    var numberPad: some View {
        VStack(spacing: 6) {
            ForEach(0..<3) { row in
                HStack(spacing: 6) {
                    ForEach(1..<4) { col in
                        numberButton(digit: row * 3 + col)
                    }
                }
            }
        }
    }

    func numberButton(digit: Int) -> some View {
        let placedCount = game.placedCount(of: digit)
        // Clamp the remaining count so non-Easy difficulties (which allow more than
        // 9 of a digit) don't display negative numbers once a duplicate sneaks in.
        let remainingDisplay = max(0, 9 - placedCount)
        let easyMode = game.difficulty == .easy
        // Exhaustion only locks the button in Easy mode — other difficulties let the
        // player place as many copies of a digit as they want.
        let exhausted = easyMode && placedCount >= 9
        // When the selected cell already holds this digit (and isn't a clue), tapping
        // it clears the cell. The button visually lowers (pushed in) to signal that.
        let clearAffordance: Bool = {
            guard let sel = game.selectedIndex else { return false }
            if game.isOriginal[sel] { return false }
            return game.values[sel] == digit
        }()
        // When the selected cell is an immutable clue, every number button is dead —
        // gray them all out to make that obvious.
        let immutableCellSelected: Bool = {
            guard let sel = game.selectedIndex else { return false }
            return game.isOriginal[sel]
        }()
        // Three visual states for the keycap: lowered (selected digit), flat (disabled
        // because the cell is locked or the digit is exhausted), and raised (default).
        let lowered = clearAffordance && !immutableCellSelected
        let flat = immutableCellSelected || (exhausted && !clearAffordance)
        let raised = !lowered && !flat
        let digitColor: Color = {
            if immutableCellSelected { return Color.white.opacity(0.18) }
            if exhausted { return Color.white.opacity(0.25) }
            if game.notesMode { return Color(red: 0.75, green: 0.85, blue: 1.0) }
            return Color.white
        }()
        let countColor: Color = immutableCellSelected
            ? Color.white.opacity(0.18)
            : Color.white.opacity(0.45)
        let backgroundFill: Color = {
            if immutableCellSelected { return Color.white.opacity(0.04) }
            if lowered {
                // Pushed-in background: noticeably darker than the raised face.
                return Color.white.opacity(0.05)
            }
            if game.notesMode {
                return Color(red: 0.18, green: 0.30, blue: 0.65).opacity(0.55)
            }
            // Default raised face — slightly brighter than the previous flat tint.
            return Color.white.opacity(0.16)
        }()
        // Top/bottom highlight stack: raised has a bright top edge over a darker
        // bottom; lowered inverts both so the keycap reads as pressed in.
        let topShade: Color
        let bottomShade: Color
        if raised {
            topShade = Color.white.opacity(0.22)
            bottomShade = Color.black.opacity(0.22)
        } else if lowered {
            topShade = Color.black.opacity(0.32)
            bottomShade = Color.white.opacity(0.12)
        } else {
            topShade = Color.clear
            bottomShade = Color.clear
        }
        let disabled = flat || game.isPaused || game.isComplete || game.isGameOver
        return Button(action: {
            // Capture whether this tap is a push-in (placing a new value) or a
            // de-press (clearing the existing same-digit) before placeDigit mutates
            // state, so the haptic matches the visual transition.
            let wasClearAffordance = clearAffordance
            game.placeDigit(digit)
            game.saveState()
            if game.isComplete {
                playHaptic(.bigCelebrate)
            } else if wasClearAffordance {
                playHaptic(depressHaptic)
            } else {
                playHaptic(pushInHaptic)
            }
        }) {
            VStack(spacing: 1) {
                Text("\(digit)")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .monospaced()
                    .foregroundStyle(digitColor)
                Text("\(remainingDisplay)")
                    .font(.system(size: 9, weight: .medium))
                    .monospaced()
                    .foregroundStyle(countColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(backgroundFill)
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(
                            colors: [topShade, Color.clear, bottomShade],
                            startPoint: .top, endPoint: .bottom
                        ))
                }
            )
            .shadow(
                color: raised ? Color.black.opacity(0.45) : Color.clear,
                radius: raised ? 2.0 : 0.0,
                x: 0.0, y: raised ? 1.5 : 0.0
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: Pause Menu Overlay

    var pauseMenuOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("PAUSED", bundle: .module)
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundStyle(.white)

                if !game.isGameOver && !game.isComplete {
                    Button(action: { resumeGame() }) {
                        Text("Resume", bundle: .module)
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .frame(width: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }

                Button(action: { showDifficultyPicker = true }) {
                    Text("New Game", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.30, green: 0.55, blue: 0.95))

                Button(action: { showSettings = true }) {
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

                if !game.isGameOver && !game.isComplete {
                    Button(action: {
                        game.giveUp()
                        showPauseMenu = false
                    }) {
                        Text("Give Up", bundle: .module)
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .frame(width: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.7, green: 0.4, blue: 0.1))
                }

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

    // MARK: Complete Overlay

    var completeOverlay: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()

            VStack(spacing: 16) {
                Text("\u{2B50}\u{2B50}\u{2B50}", bundle: .module)
                    .font(.system(size: 36))
                Text("Puzzle Solved!", bundle: .module)
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundStyle(
                        LinearGradient(colors: [Color.yellow, Color.orange],
                                       startPoint: .top, endPoint: .bottom))

                VStack(spacing: 6) {
                    statLine(title: "Time", value: formatTime(game.elapsedSeconds),
                             color: Color(red: 0.60, green: 0.85, blue: 1.0))

                    let best = game.bestTime(for: game.difficulty)
                    if best == game.elapsedSeconds && best > 0 {
                        Text("New Best Time!", bundle: .module)
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(.yellow)
                    } else if best > 0 {
                        Text("Best: \(formatTime(best))")
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.65))
                    }
                }

                Button(action: { showDifficultyPicker = true }) {
                    Text("Play Again", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .padding(.top, 4.0)

                Button(action: { dismiss() }) {
                    Text("Quit Game", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                ShareLink(
                    item: "I solved a \(game.difficulty.label) Sudoku in \(formatTime(game.elapsedSeconds)) on Faire Games! Can you beat it?\nhttps://appfair.net",
                    subject: Text("Sudoku Time", bundle: .module),
                    message: Text("I solved Sudoku in \(formatTime(game.elapsedSeconds))!")
                ) {
                    HStack(spacing: 6) {
                        Image("ios_share", bundle: .module)
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                        Text("Share", bundle: .module)
                            .font(.subheadline)
                    }
                    .foregroundStyle(Color.white.opacity(0.7))
                }
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.18))
            )
        }
    }

    func statLine(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.6))
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(color)
                .monospaced()
        }
    }

    // MARK: Pause / Resume / Timer

    func pauseGame() {
        guard !showPauseMenu else { return }
        // After Give Up (or completion) the game is already stopped — just surface
        // the menu so the player can start a new game or quit.
        if !game.isComplete && !game.isGameOver {
            game.isPaused = true
        }
        showPauseMenu = true
    }

    func resumeGame() {
        showPauseMenu = false
        game.isPaused = false
    }

    func startTimer() {
        stopTimer()
        timerTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                game.tick()
            }
        }
    }

    func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }
}

// MARK: - Difficulty Picker

struct DifficultyPickerView: View {
    let currentDifficulty: SudokuDifficulty
    let onSelect: (SudokuDifficulty) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Text("Choose Difficulty", bundle: .module)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                        .padding(.top, 10.0)

                    ForEach(SudokuDifficulty.allCases) { d in
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
                                    Text(d.detail)
                                        .font(.caption)
                                        .foregroundStyle(Color.white.opacity(0.6))
                                }
                                Spacer()
                                if d == currentDifficulty {
                                    Image("check_circle", bundle: .module)
                                        .renderingMode(.template)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 22, height: 22)
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
                                    .stroke(d.accentColor.opacity(0.45), lineWidth: 1.5)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20.0)
                .padding(.bottom, 24.0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.05, green: 0.06, blue: 0.14).ignoresSafeArea())
            .navigationTitle(Text("New Game", bundle: .module))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) { Text("Cancel", bundle: .module) }
                        .foregroundStyle(Color.white)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Helpers

func formatTime(_ seconds: Int) -> String {
    let m = seconds / 60
    let s = seconds % 60
    let mStr = m < 10 ? "0\(m)" : "\(m)"
    let sStr = s < 10 ? "0\(s)" : "\(s)"
    return "\(mStr):\(sStr)"
}

// MARK: - Preview Icon

public struct SudokuPreviewIcon: View {
    public init() { }

    // A small 4x4 mini representation (clean enough to be identifiable at icon size)
    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.15, blue: 0.30),
                         Color(red: 0.05, green: 0.08, blue: 0.18)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            // 3x3 grid of 3x3 sub-grids
            VStack(spacing: 2) {
                ForEach(0..<3) { br in
                    HStack(spacing: 2) {
                        ForEach(0..<3) { bc in
                            miniBox(bandRow: br, bandCol: bc)
                        }
                    }
                }
            }
            .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func miniBox(bandRow: Int, bandCol: Int) -> some View {
        // Use canonical digits for a pleasing icon look
        let pattern = [
            // 9 values laid out as 3x3
            ["5", ".", ".", "6", "7", "8", ".", "1", "2"],
            ["6", "7", ".", ".", "9", "5", "3", ".", "8"],
            [".", "9", "8", "3", ".", "2", "5", "6", "."],
            [".", "5", "9", "7", ".", "1", ".", "2", "3"],
            ["4", ".", "6", ".", "5", ".", "7", ".", "."],
            ["7", "1", ".", ".", "2", "4", "8", "5", "."],
            [".", "6", "1", ".", "3", ".", "2", "8", "4"],
            [".", "8", ".", "4", "1", ".", "6", ".", "."],
            ["3", ".", "5", ".", "8", "6", ".", "7", "9"]
        ]
        let boxIndex = bandRow * 3 + bandCol
        let digits = pattern[boxIndex]
        return VStack(spacing: 1) {
            ForEach(0..<3) { r in
                HStack(spacing: 1) {
                    ForEach(0..<3) { c in
                        let v = digits[r * 3 + c]
                        Text(v)
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(v == "."
                                             ? Color.clear
                                             : colorFor(digit: v, box: boxIndex))
                            .monospaced()
                            .frame(width: 10, height: 10)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(1)
                    }
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white.opacity(0.04))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        }
    }

    private func colorFor(digit: String, box: Int) -> Color {
        // Color "given" digits with slight variation for visual interest
        let palette: [Color] = [
            Color.white,
            Color(red: 0.65, green: 0.85, blue: 1.0),
            Color(red: 1.0, green: 0.75, blue: 0.55)
        ]
        return palette[(box + (Int(digit) ?? 0)) % palette.count]
    }
}

// MARK: - Settings View

struct SudokuSettingsView: View {
    @Bindable var settings: SudokuSettings
    @Environment(\.dismiss) var dismiss
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Sudoku", bundle: .module)) {
                    Toggle(isOn: $settings.vibrations) { Text("Vibrations", bundle: .module) }
                    Picker(selection: $settings.lastDifficulty) {
                        ForEach(SudokuDifficulty.allCases) { d in
                            Text(d.label).tag(d)
                        }
                    } label: {
                        Text("Default Difficulty", bundle: .module)
                    }
                }
                Section(header: Text("Records", bundle: .module)) {
                    recordRow(for: SudokuDifficulty.easy)
                    recordRow(for: SudokuDifficulty.medium)
                    recordRow(for: SudokuDifficulty.hard)
                    recordRow(for: SudokuDifficulty.expert)
                    HStack {
                        Text("Puzzles Solved", bundle: .module)
                        Spacer()
                        Text("\(UserDefaults.standard.integer(forKey: "sudoku_puzzles_solved"))")
                            .foregroundStyle(Color.secondary)
                            .monospaced()
                    }
                }
                Section(header: Text("Data", bundle: .module)) {
                    Button(role: .destructive, action: { confirmReset = true }) {
                        Text("Reset Sudoku Records", bundle: .module)
                    }
                    .confirmationDialog(Text("Reset Sudoku Records?", bundle: .module),
                                        isPresented: $confirmReset,
                                        titleVisibility: .visible) {
                        Button(role: ButtonRole.destructive, action: {
                            resetSudokuRecords()
                        }) { Text("Reset", bundle: .module) }
                    } message: {
                        Text("This will permanently reset all Sudoku best times and puzzle counts.", bundle: .module)
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

    func recordRow(for difficulty: SudokuDifficulty) -> some View {
        let best = UserDefaults.standard.integer(forKey: difficulty.bestTimeKey)
        return HStack {
            Text(difficulty.label)
            Spacer()
            Text(best > 0 ? formatTime(best) : "—")
                .foregroundStyle(.secondary)
                .monospaced()
        }
    }
}

@Observable
public class SudokuSettings {
    public var vibrations: Bool = defaults.value(forKey: "sudokuVibrations", default: true) {
        didSet { defaults.set(vibrations, forKey: "sudokuVibrations") }
    }

    public var lastDifficulty: SudokuDifficulty =
        SudokuDifficulty(rawValue: defaults.value(forKey: "sudokuLastDifficulty", default: 1)) ?? .medium {
        didSet { defaults.set(lastDifficulty.rawValue, forKey: "sudokuLastDifficulty") }
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
