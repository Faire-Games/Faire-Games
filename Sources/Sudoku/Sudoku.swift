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

    /// Whether this difficulty tracks and penalizes mistakes.
    var tracksMistakes: Bool {
        switch self {
        case .easy, .medium: return true
        case .hard, .expert: return false
        }
    }

    /// Whether hints are available at this difficulty.
    var hintsEnabled: Bool {
        switch self {
        case .easy, .medium, .hard: return true
        case .expert: return false
        }
    }

    /// Description shown in the difficulty picker.
    var detail: String {
        switch self {
        case .easy: return "\(cluesCount) clues \u{2022} 3 hints \u{2022} mistakes tracked"
        case .medium: return "\(cluesCount) clues \u{2022} 3 hints \u{2022} mistakes tracked"
        case .hard: return "\(cluesCount) clues \u{2022} 3 hints \u{2022} no mistake warnings"
        case .expert: return "\(cluesCount) clues \u{2022} no hints \u{2022} no mistake warnings"
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
    var difficultyRaw: Int
    var mistakes: Int
    var hintsRemaining: Int
    var elapsedSeconds: Int
    var isComplete: Bool
    var isGameOver: Bool
    var undoIndices: [Int]
    var undoValues: [Int]
    var undoNotes: [Int]
    var undoNotesModified: [Bool]
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

    // Interaction state
    var selectedIndex: Int? = nil
    var notesMode: Bool = false

    // Progress
    var difficulty: SudokuDifficulty = .medium
    var mistakes: Int = 0
    var maxMistakes: Int = 3
    var hintsRemaining: Int = 3
    var elapsedSeconds: Int = 0
    var isPaused: Bool = false
    var isComplete: Bool = false
    var isGameOver: Bool = false
    var hasGivenUp: Bool = false

    // Records
    var bestEasy: Int = UserDefaults.standard.integer(forKey: "sudoku_best_easy")
    var bestMedium: Int = UserDefaults.standard.integer(forKey: "sudoku_best_medium")
    var bestHard: Int = UserDefaults.standard.integer(forKey: "sudoku_best_hard")
    var bestExpert: Int = UserDefaults.standard.integer(forKey: "sudoku_best_expert")
    var puzzlesSolved: Int = UserDefaults.standard.integer(forKey: "sudoku_puzzles_solved")

    // Undo stack — records (index, oldValue, oldNotes) triples as parallel arrays
    var undoIndices: [Int] = []
    var undoValues: [Int] = []
    var undoNotes: [Int] = []
    var undoNotesModified: [Bool] = []

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
        selectedIndex = nil
        notesMode = false
        mistakes = 0
        hintsRemaining = difficulty.hintsEnabled ? 3 : 0
        elapsedSeconds = 0
        isPaused = false
        isComplete = false
        isGameOver = false
        hasGivenUp = false
        undoIndices.removeAll()
        undoValues.removeAll()
        undoNotes.removeAll()
        undoNotesModified.removeAll()
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

    /// Whether the given cell conflicts with another equal-value cell in its row, col, or box.
    func hasConflict(at index: Int) -> Bool {
        let v = values[index]
        if v == 0 { return false }
        let row = index / 9
        let col = index % 9
        // Row
        for c in 0..<9 {
            if c != col && values[idx(row, c)] == v { return true }
        }
        // Col
        for r in 0..<9 {
            if r != row && values[idx(r, col)] == v { return true }
        }
        // Box
        let boxRow = (row / 3) * 3
        let boxCol = (col / 3) * 3
        for r in boxRow..<(boxRow + 3) {
            for c in boxCol..<(boxCol + 3) {
                if (r != row || c != col) && values[idx(r, c)] == v { return true }
            }
        }
        return false
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

    private func pushUndo(_ cellIndex: Int, modifiedNotes: Bool) {
        undoIndices.append(cellIndex)
        undoValues.append(values[cellIndex])
        undoNotes.append(notes[cellIndex])
        undoNotesModified.append(modifiedNotes)
        // Cap undo history to avoid unbounded growth
        if undoIndices.count > 100 {
            undoIndices.removeFirst()
            undoValues.removeFirst()
            undoNotes.removeFirst()
            undoNotesModified.removeFirst()
        }
    }

    /// Attempt to place `digit` into the selected cell. Returns true if a value change occurred.
    @discardableResult
    func placeDigit(_ digit: Int) -> Bool {
        guard let i = selectedIndex, !isPaused, !isComplete, !isGameOver else { return false }
        if isOriginal[i] { return false }
        if notesMode {
            pushUndo(i, modifiedNotes: true)
            toggleNote(i, digit)
            return true
        }
        // If the cell already has this digit, treat as clear
        if values[i] == digit {
            pushUndo(i, modifiedNotes: false)
            values[i] = 0
            return true
        }
        pushUndo(i, modifiedNotes: false)
        values[i] = digit
        clearNotes(i)
        if digit != solution[i] {
            if difficulty.tracksMistakes {
                mistakes += 1
                if mistakes >= maxMistakes {
                    isGameOver = true
                }
            }
        } else {
            // Correct placement: clear this digit from peer notes
            clearPeerNotes(of: i, digit: digit)
            checkCompletion()
        }
        return true
    }

    func erase() {
        guard let i = selectedIndex, !isPaused, !isComplete, !isGameOver else { return }
        if isOriginal[i] { return }
        if values[i] == 0 && notes[i] == 0 { return }
        pushUndo(i, modifiedNotes: notes[i] != 0)
        values[i] = 0
        notes[i] = 0
    }

    func undo() {
        guard !undoIndices.isEmpty else { return }
        let i = undoIndices.removeLast()
        let v = undoValues.removeLast()
        let n = undoNotes.removeLast()
        let _ = undoNotesModified.removeLast()
        values[i] = v
        notes[i] = n
    }

    /// Use a hint to auto-fill the correct value into the selected cell.
    /// If no cell is selected, picks the first empty cell.
    func useHint() {
        guard hintsRemaining > 0, !isPaused, !isComplete, !isGameOver else { return }
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
        pushUndo(i, modifiedNotes: notes[i] != 0)
        values[i] = solution[i]
        notes[i] = 0
        hintsRemaining -= 1
        selectedIndex = i
        clearPeerNotes(of: i, digit: solution[i])
        checkCompletion()
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
        // Fill all empty cells with the solution
        for i in 0..<81 {
            if values[i] == 0 {
                values[i] = solution[i]
            }
        }
        hasGivenUp = true
        isGameOver = true
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
            difficultyRaw: difficulty.rawValue,
            mistakes: mistakes,
            hintsRemaining: hintsRemaining,
            elapsedSeconds: elapsedSeconds,
            isComplete: isComplete,
            isGameOver: isGameOver,
            undoIndices: undoIndices,
            undoValues: undoValues,
            undoNotes: undoNotes,
            undoNotesModified: undoNotesModified
        )
    }

    func restoreState(_ state: SudokuSavedState) {
        values = state.values
        isOriginal = state.isOriginal
        solution = state.solution
        notes = state.notes
        difficulty = SudokuDifficulty(rawValue: state.difficultyRaw) ?? .medium
        mistakes = state.mistakes
        hintsRemaining = state.hintsRemaining
        elapsedSeconds = state.elapsedSeconds
        isComplete = state.isComplete
        isGameOver = state.isGameOver
        undoIndices = state.undoIndices
        undoValues = state.undoValues
        undoNotes = state.undoNotes
        undoNotesModified = state.undoNotesModified
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
                } else if game.isGameOver {
                    gameOverOverlay
                } else if showPauseMenu {
                    pauseMenuOverlay
                }
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
            if game.difficulty.tracksMistakes {
                statusPill(title: "Mistakes", value: "\(game.mistakes)/\(game.maxMistakes)",
                           tint: game.mistakes >= game.maxMistakes
                                ? Color(red: 0.95, green: 0.30, blue: 0.30)
                                : (game.mistakes > 0
                                   ? Color(red: 0.95, green: 0.70, blue: 0.30)
                                   : Color(red: 0.55, green: 0.85, blue: 0.55)))
                Spacer(minLength: 8)
            }
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
        let isConflict = game.difficulty.tracksMistakes && game.hasConflict(at: index)
        let highlightLevel = computeHighlight(for: index)
        // A cell filled by "Give Up" is one that wasn't original and now matches solution after giving up
        let isGivenUpCell = game.hasGivenUp && !isOriginal && value == game.solution[index]
        return ZStack {
            // Background
            Rectangle()
                .fill(cellBackground(isSelected: isSelected,
                                     highlight: highlightLevel,
                                     isConflict: isConflict))

            if value != 0 {
                Text("\(value)")
                    .font(.system(size: size * 0.55, weight: isOriginal ? .black : .semibold, design: .rounded))
                    .foregroundStyle(cellTextColor(isOriginal: isOriginal,
                                                   isConflict: isConflict,
                                                   isCorrect: value == game.solution[index],
                                                   isGivenUpSolution: isGivenUpCell))
                    .monospaced()
            } else {
                notesGridView(index: index, cellSize: size)
            }
        }
        .frame(width: size, height: size)
    }

    func notesGridView(index: Int, cellSize: Double) -> some View {
        let noteFont = cellSize * 0.22
        return GeometryReader { _ in
            ZStack {
                ForEach(1..<10) { d in
                    let row = (d - 1) / 3
                    let col = (d - 1) % 3
                    if game.hasNote(index, d) {
                        Text("\(d)")
                            .font(.system(size: noteFont, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.55))
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
    func computeHighlight(for index: Int) -> Int {
        guard let sel = game.selectedIndex else { return 0 }
        if sel == index { return 3 }
        let selValue = game.values[sel]
        if selValue != 0 && game.values[index] == selValue { return 2 }
        if game.isPeer(sel, index) { return 1 }
        return 0
    }

    func cellBackground(isSelected: Bool, highlight: Int, isConflict: Bool) -> Color {
        if isConflict && highlight != 3 {
            return Color(red: 0.45, green: 0.15, blue: 0.20).opacity(0.55)
        }
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

    func cellTextColor(isOriginal: Bool, isConflict: Bool, isCorrect: Bool, isGivenUpSolution: Bool) -> Color {
        if isGivenUpSolution {
            return Color(red: 0.55, green: 0.65, blue: 0.80).opacity(0.55)
        }
        if isConflict {
            return Color(red: 1.0, green: 0.55, blue: 0.55)
        }
        if isOriginal {
            return Color.white
        }
        if !game.difficulty.tracksMistakes {
            // Hard/Expert: don't color-code correctness
            return Color(red: 0.65, green: 0.85, blue: 1.0)
        }
        return isCorrect
            ? Color(red: 0.65, green: 0.85, blue: 1.0)
            : Color(red: 1.0, green: 0.70, blue: 0.55)
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
        HStack(spacing: 8) {
            // Left column: Notes (top), Hint (bottom)
            VStack(spacing: 8) {
                actionButton(label: game.notesMode ? "Notes ✓" : "Notes",
                             iconName: "edit",
                             highlighted: game.notesMode,
                             disabled: game.isPaused || game.isGameOver || game.isComplete,
                             action: {
                                 game.notesMode.toggle()
                                 playHaptic(.pick)
                             })
                actionButton(label: "Hint (\(game.hintsRemaining))",
                             iconName: "lightbulb",
                             disabled: game.hintsRemaining == 0 || game.isPaused || game.isGameOver || game.isComplete,
                             action: {
                                 game.useHint()
                                 game.saveState()
                                 playHaptic(.snap)
                             })
            }
            .frame(width: 64)

            // Center: 3x3 number grid
            numberPad

            // Right column: Undo (top), Erase (bottom)
            VStack(spacing: 8) {
                actionButton(label: "Undo", iconName: "undo",
                             disabled: game.undoIndices.isEmpty || game.isPaused || game.isGameOver || game.isComplete,
                             action: {
                                 game.undo()
                                 game.saveState()
                                 playHaptic(.pick)
                             })
                actionButton(label: "Erase", iconName: "ink_eraser",
                             disabled: game.selectedIndex == nil || game.isPaused || game.isGameOver || game.isComplete,
                             action: {
                                 game.erase()
                                 game.saveState()
                                 playHaptic(.pick)
                             })
            }
            .frame(width: 64)
        }
    }

    func actionButton(label: String, iconName: String, highlighted: Bool = false, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(iconName, bundle: .module)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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
        let remaining = 9 - game.placedCount(of: digit)
        let exhausted = remaining <= 0
        return Button(action: {
            game.placeDigit(digit)
            game.saveState()
            playHaptic(.pick)
        }) {
            VStack(spacing: 1) {
                Text("\(digit)")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .monospaced()
                    .foregroundStyle(exhausted
                                     ? Color.white.opacity(0.25)
                                     : (game.notesMode
                                        ? Color(red: 0.75, green: 0.85, blue: 1.0)
                                        : Color.white))
                Text("\(remaining)")
                    .font(.system(size: 9, weight: .medium))
                    .monospaced()
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(game.notesMode
                          ? Color(red: 0.15, green: 0.25, blue: 0.55).opacity(0.45)
                          : Color.white.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .disabled(exhausted || game.isPaused || game.isComplete || game.isGameOver)
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

                Button(action: { resumeGame() }) {
                    Text("Resume", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

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
                    HStack(spacing: 24) {
                        statLine(title: "Time", value: formatTime(game.elapsedSeconds),
                                 color: Color(red: 0.60, green: 0.85, blue: 1.0))
                        statLine(title: "Mistakes", value: "\(game.mistakes)",
                                 color: Color(red: 1.0, green: 0.80, blue: 0.60))
                    }

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

    // MARK: Game Over Overlay

    var gameOverOverlay: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()

            VStack(spacing: 16) {
                Text("GAME OVER", bundle: .module)
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundStyle(.white)
                Text("Too many mistakes", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.65))

                HStack(spacing: 24) {
                    statLine(title: "Time", value: formatTime(game.elapsedSeconds),
                             color: Color(red: 0.60, green: 0.85, blue: 1.0))
                    statLine(title: "Mistakes", value: "\(game.mistakes)",
                             color: Color(red: 1.0, green: 0.50, blue: 0.50))
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
        guard !showPauseMenu && !game.isComplete && !game.isGameOver else { return }
        game.isPaused = true
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
                    Toggle(isOn: $settings.highlightMistakes) { Text("Highlight Mistakes", bundle: .module) }
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

    public var highlightMistakes: Bool = defaults.value(forKey: "sudokuHighlightMistakes", default: true) {
        didSet { defaults.set(highlightMistakes, forKey: "sudokuHighlightMistakes") }
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
