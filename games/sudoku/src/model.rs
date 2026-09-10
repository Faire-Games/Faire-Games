//! The Sudoku game state — board, notes, cursor-based undo/redo, checkpoints, hints, pause,
//! records, and settings — mirroring Faire-Games' SudokuModel. Pure logic, no UI: everything
//! here is host-testable with `cargo test`.

use serde::{Deserialize, Serialize};

/// Cell index = row * 9 + col.
pub const CELLS: usize = 81;

#[inline]
pub fn idx(row: usize, col: usize) -> usize {
    row * 9 + col
}

/// A tiny xorshift RNG — no `rand` dependency, deterministic per seed.
pub struct Rng(pub u64);
impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
    /// A random index in `0..3` other than `not`.
    fn other(&mut self, not: usize) -> usize {
        (not + 1 + self.below(2)) % 3
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub enum Difficulty {
    Easy,
    Medium,
    Hard,
    Expert,
}

pub const DIFFICULTIES: [Difficulty; 4] = [
    Difficulty::Easy,
    Difficulty::Medium,
    Difficulty::Hard,
    Difficulty::Expert,
];

impl Difficulty {
    /// Number of clues (filled cells) the puzzle keeps.
    pub fn clues(self) -> usize {
        match self {
            Difficulty::Easy => 46,
            Difficulty::Medium => 36,
            Difficulty::Hard => 30,
            Difficulty::Expert => 26,
        }
    }
    /// Starting hint budget; `None` = unlimited (Easy). Hard and Expert grant none.
    pub fn hints(self) -> Option<i32> {
        match self {
            Difficulty::Easy => None,
            Difficulty::Medium => Some(3),
            Difficulty::Hard | Difficulty::Expert => Some(0),
        }
    }
    pub fn unlimited_hints(self) -> bool {
        self.hints().is_none()
    }
    pub fn hints_enabled(self) -> bool {
        self.hints() != Some(0)
    }
    /// Expert hides the same-number highlight.
    pub fn highlights_same_digit(self) -> bool {
        !matches!(self, Difficulty::Expert)
    }
    /// Easy flags a placed digit that duplicates a peer, and locks a digit's key once all
    /// nine are placed; the other difficulties leave the player to spot both.
    pub fn flags_mistakes(self) -> bool {
        matches!(self, Difficulty::Easy)
    }
    pub fn index(self) -> usize {
        match self {
            Difficulty::Easy => 0,
            Difficulty::Medium => 1,
            Difficulty::Hard => 2,
            Difficulty::Expert => 3,
        }
    }
    pub fn from_index(i: usize) -> Difficulty {
        DIFFICULTIES.get(i).copied().unwrap_or(Difficulty::Medium)
    }
}

/// One cell's editable state, as captured in history entries.
#[derive(Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct CellSnap {
    pub value: u8,
    pub notes: u16,
    pub provisional: bool,
}

/// One undoable edit: the edited cell's before/after, plus the peer cells whose pencil
/// marks the edit stripped as a side effect (index, old notes, new notes).
#[derive(Clone, Serialize, Deserialize)]
pub struct Edit {
    pub i: usize,
    pub old: CellSnap,
    pub new: CellSnap,
    pub peers: Vec<(usize, u16, u16)>,
}

/// Per-difficulty best times (seconds; 0 = none yet) and the total solved count. Persisted
/// on their own so they outlive any one puzzle and a records reset touches nothing else.
#[derive(Clone, Default, Serialize, Deserialize, PartialEq, Debug)]
pub struct Records {
    pub best: [u64; 4],
    pub solved: u64,
}

/// The player's Sudoku settings (persisted on their own).
#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
pub struct Settings {
    pub vibrations: bool,
    /// The difficulty a fresh puzzle takes; the picker updates it.
    pub default_difficulty: Difficulty,
    /// The instructions sheet opens by itself the first time the game is played.
    pub instructions_shown: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            vibrations: true,
            default_difficulty: Difficulty::Medium,
            instructions_shown: false,
        }
    }
}

/// The durable whole-puzzle snapshot (gamekit save/restore).
#[derive(Serialize, Deserialize)]
pub struct SaveState {
    pub values: Vec<u8>,
    pub original: Vec<bool>,
    pub solution: Vec<u8>,
    pub notes: Vec<u16>,
    pub provisional: Vec<bool>,
    pub given_up_fill: Vec<bool>,
    pub notes_mode: bool,
    pub checkpoint_active: bool,
    pub checkpoint_values: Vec<u8>,
    pub checkpoint_notes: Vec<u16>,
    pub checkpoint_cursor: usize,
    pub difficulty: Difficulty,
    pub hints_remaining: i32, // -1 = unlimited
    pub elapsed_secs: u64,
    pub complete: bool,
    pub given_up: bool,
    pub history: Vec<Edit>,
    pub cursor: usize,
}

pub struct Model {
    pub values: Vec<u8>,
    pub original: Vec<bool>,
    pub solution: Vec<u8>,
    /// Pencil marks per cell: bit d (1–9) set = candidate d noted.
    pub notes: Vec<u16>,
    /// Placed during the current checkpoint session (rendered distinctly).
    pub provisional: Vec<bool>,
    /// Auto-filled by Give Up (rendered distinctly from user entries).
    pub given_up_fill: Vec<bool>,

    pub selected: Option<usize>,
    pub notes_mode: bool,
    /// The clock is stopped and input ignored while the pause menu is up.
    pub paused: bool,

    pub checkpoint_active: bool,
    checkpoint_values: Vec<u8>,
    checkpoint_notes: Vec<u16>,
    checkpoint_cursor: usize,

    pub difficulty: Difficulty,
    /// Hints left; -1 = unlimited (Easy).
    pub hints_remaining: i32,
    pub elapsed: f64,
    pub complete: bool,
    pub given_up: bool,
    /// The just-finished solve set a new best time (for the solved overlay).
    pub new_best: bool,

    // Cursor-based history: history[..cursor] undoable, history[cursor..] redoable.
    history: Vec<Edit>,
    cursor: usize,

    pub records: Records,
    rng: Rng,
}

impl Model {
    pub fn new(seed: u64, difficulty: Difficulty) -> Model {
        let mut m = Model {
            values: vec![0; CELLS],
            original: vec![false; CELLS],
            solution: vec![0; CELLS],
            notes: vec![0; CELLS],
            provisional: vec![false; CELLS],
            given_up_fill: vec![false; CELLS],
            selected: None,
            notes_mode: false,
            paused: false,
            checkpoint_active: false,
            checkpoint_values: vec![0; CELLS],
            checkpoint_notes: vec![0; CELLS],
            checkpoint_cursor: 0,
            difficulty,
            hints_remaining: 0,
            elapsed: 0.0,
            complete: false,
            given_up: false,
            new_best: false,
            history: Vec::new(),
            cursor: 0,
            records: Records::default(),
            rng: Rng(seed | 1),
        };
        m.new_game(difficulty);
        m
    }

    /// Start a fresh puzzle at `difficulty`, keeping the records.
    pub fn new_game(&mut self, difficulty: Difficulty) {
        self.difficulty = difficulty;
        let (puzzle, solution) = generate_puzzle(&mut self.rng, difficulty);
        self.solution = solution;
        self.values = puzzle;
        self.original = self.values.iter().map(|&v| v != 0).collect();
        self.notes = vec![0; CELLS];
        self.provisional = vec![false; CELLS];
        self.given_up_fill = vec![false; CELLS];
        self.selected = None;
        self.notes_mode = false;
        self.paused = false;
        self.checkpoint_active = false;
        self.checkpoint_values = vec![0; CELLS];
        self.checkpoint_notes = vec![0; CELLS];
        self.checkpoint_cursor = 0;
        self.hints_remaining = difficulty.hints().unwrap_or(-1);
        self.elapsed = 0.0;
        self.complete = false;
        self.given_up = false;
        self.new_best = false;
        self.history.clear();
        self.cursor = 0;
    }

    /// The game ended (solved or given up): the board is frozen for good.
    pub fn locked(&self) -> bool {
        self.complete || self.given_up
    }

    /// Input is ignored: the game ended or the pause menu is up.
    pub fn busy(&self) -> bool {
        self.locked() || self.paused
    }

    pub fn can_undo(&self) -> bool {
        self.cursor > 0 && !self.busy()
    }
    pub fn can_redo(&self) -> bool {
        self.cursor < self.history.len() && !self.busy()
    }
    /// The difficulty grants hints and the budget is not spent.
    pub fn can_hint(&self) -> bool {
        !self.busy() && self.difficulty.hints_enabled() && self.hints_remaining != 0
    }

    /// Same row, column, or 3×3 box (excluding identity).
    pub fn is_peer(a: usize, b: usize) -> bool {
        if a == b {
            return false;
        }
        let (ar, ac, br, bc) = (a / 9, a % 9, b / 9, b % 9);
        ar == br || ac == bc || (ar / 3 == br / 3 && ac / 3 == bc / 3)
    }

    /// A filled cell conflicts when a peer holds the same digit.
    pub fn has_conflict(&self, i: usize) -> bool {
        let v = self.values[i];
        if v == 0 {
            return false;
        }
        (0..CELLS).any(|j| Self::is_peer(i, j) && self.values[j] == v)
    }

    /// A user-placed digit Easy mode flags red: it duplicates a peer.
    pub fn is_obvious_mistake(&self, i: usize) -> bool {
        !self.original[i]
            && self.values[i] != 0
            && self.difficulty.flags_mistakes()
            && self.has_conflict(i)
    }

    /// After Give Up: a digit the player placed that is not the solution's.
    pub fn is_user_wrong(&self, i: usize) -> bool {
        self.given_up
            && !self.original[i]
            && !self.given_up_fill[i]
            && self.values[i] != 0
            && self.values[i] != self.solution[i]
    }

    /// How many of digit `d` are placed (the keypad's remaining count).
    pub fn placed_count(&self, d: u8) -> usize {
        self.values.iter().filter(|&&v| v == d).count()
    }

    /// Easy locks a digit's key once all nine are placed; the others let duplicates through.
    pub fn is_exhausted(&self, d: u8) -> bool {
        self.difficulty.flags_mistakes() && self.placed_count(d) >= 9
    }

    /// The selected cell is a clue: every digit key is dead.
    pub fn clue_selected(&self) -> bool {
        self.selected.is_some_and(|s| self.original[s])
    }

    /// The selected cell already holds `d`: tapping the key clears it.
    pub fn clears_with(&self, d: u8) -> bool {
        self.selected
            .is_some_and(|s| !self.original[s] && self.values[s] == d)
    }

    fn snap(&self, i: usize) -> CellSnap {
        CellSnap {
            value: self.values[i],
            notes: self.notes[i],
            provisional: self.provisional[i],
        }
    }

    fn push_history(&mut self, i: usize, old: CellSnap, peers: Vec<(usize, u16, u16)>) {
        self.history.truncate(self.cursor);
        self.history.push(Edit {
            i,
            old,
            new: self.snap(i),
            peers,
        });
        self.cursor = self.history.len();
    }

    /// Strip `digit` from every peer's pencil marks, recording each change so undo restores it.
    /// Done whether or not the guess is right, so the side effect reveals nothing.
    fn strip_peer_notes(&mut self, i: usize, digit: u8) -> Vec<(usize, u16, u16)> {
        let mut peers = Vec::new();
        for j in 0..CELLS {
            if Self::is_peer(i, j) && self.notes[j] & (1 << digit) != 0 {
                let before = self.notes[j];
                self.notes[j] &= !(1 << digit);
                peers.push((j, before, self.notes[j]));
            }
        }
        peers
    }

    /// Enter a digit (or toggle a note) into the selected cell — Faire's placeDigit.
    /// Returns true when something changed.
    pub fn place(&mut self, digit: u8) -> bool {
        let Some(i) = self.selected else { return false };
        if self.busy() || self.original[i] || !(1..=9).contains(&digit) {
            return false;
        }
        let old = self.snap(i);
        if self.notes_mode {
            if self.values[i] != 0 {
                return false; // notes live in empty cells
            }
            self.notes[i] ^= 1 << digit;
            if self.checkpoint_active {
                self.provisional[i] = true;
            }
            self.push_history(i, old, Vec::new());
            return true;
        }
        if self.values[i] == digit {
            // Entering the same digit clears it.
            self.values[i] = 0;
            self.provisional[i] = false;
            self.push_history(i, old, Vec::new());
            return true;
        }
        if self.is_exhausted(digit) {
            return false;
        }
        self.values[i] = digit;
        self.notes[i] = 0;
        self.provisional[i] = self.checkpoint_active;
        let peers = self.strip_peer_notes(i, digit);
        self.push_history(i, old, peers);
        self.check_completion();
        true
    }

    /// Clear the selected cell's value and notes (the Delete key on desktop).
    pub fn erase(&mut self) -> bool {
        let Some(i) = self.selected else { return false };
        if self.busy() || self.original[i] || (self.values[i] == 0 && self.notes[i] == 0) {
            return false;
        }
        let old = self.snap(i);
        self.values[i] = 0;
        self.notes[i] = 0;
        self.provisional[i] = false;
        self.push_history(i, old, Vec::new());
        true
    }

    /// Move the selection by one cell (the arrow keys), starting at the center when nothing
    /// is selected.
    pub fn move_selection(&mut self, dr: i32, dc: i32) {
        if self.busy() {
            return;
        }
        let (r, c) = match self.selected {
            Some(i) => ((i / 9) as i32, (i % 9) as i32),
            None => (4, 4),
        };
        let r = (r + dr).clamp(0, 8) as usize;
        let c = (c + dc).clamp(0, 8) as usize;
        self.selected = Some(idx(r, c));
    }

    pub fn undo(&mut self) {
        if !self.can_undo() {
            return;
        }
        self.cursor -= 1;
        let e = self.history[self.cursor].clone();
        self.values[e.i] = e.old.value;
        self.notes[e.i] = e.old.notes;
        self.provisional[e.i] = e.old.provisional;
        for (j, before, _) in &e.peers {
            self.notes[*j] = *before;
        }
    }

    pub fn redo(&mut self) {
        if !self.can_redo() {
            return;
        }
        let e = self.history[self.cursor].clone();
        self.values[e.i] = e.new.value;
        self.notes[e.i] = e.new.notes;
        self.provisional[e.i] = e.new.provisional;
        for (j, _, after) in &e.peers {
            self.notes[*j] = *after;
        }
        self.cursor += 1;
        self.check_completion();
    }

    /// Fill the correct digit into the selected cell, or the first empty or wrong one. A hint
    /// is committed even inside a checkpoint — the player asked for the answer.
    pub fn hint(&mut self) -> bool {
        if !self.can_hint() {
            return false;
        }
        let wrong = |m: &Model, i: usize| !m.original[i] && m.values[i] != m.solution[i];
        let target = match self.selected {
            Some(i) if wrong(self, i) => Some(i),
            _ => (0..CELLS).find(|&i| wrong(self, i)),
        };
        let Some(i) = target else { return false };
        let old = self.snap(i);
        let sol = self.solution[i];
        self.values[i] = sol;
        self.notes[i] = 0;
        self.provisional[i] = false;
        if self.hints_remaining > 0 {
            self.hints_remaining -= 1;
        }
        self.selected = Some(i);
        let peers = self.strip_peer_notes(i, sol);
        self.push_history(i, old, peers);
        self.check_completion();
        true
    }

    /// Bookmark the current position: later edits render provisional until the checkpoint
    /// is committed (keep them) or reverted (drop them). Entering drops the redo tail.
    pub fn enter_checkpoint(&mut self) {
        if self.busy() || self.checkpoint_active {
            return;
        }
        self.history.truncate(self.cursor);
        self.checkpoint_values = self.values.clone();
        self.checkpoint_notes = self.notes.clone();
        self.checkpoint_cursor = self.cursor;
        self.checkpoint_active = true;
    }

    /// Keep everything placed during the checkpoint session.
    pub fn commit_checkpoint(&mut self) {
        if !self.checkpoint_active {
            return;
        }
        self.provisional = vec![false; CELLS];
        self.checkpoint_active = false;
        self.history.clear();
        self.cursor = 0;
    }

    /// Drop everything placed during the checkpoint session; pre-checkpoint moves stay
    /// undoable.
    pub fn revert_checkpoint(&mut self) {
        if !self.checkpoint_active {
            return;
        }
        self.values = self.checkpoint_values.clone();
        self.notes = self.checkpoint_notes.clone();
        self.provisional = vec![false; CELLS];
        self.checkpoint_active = false;
        self.history.truncate(self.checkpoint_cursor);
        self.cursor = self.checkpoint_cursor;
    }

    /// Reveal the solution in the EMPTY cells and lock the board. The player's own wrong
    /// entries stay, so the post-mortem shows them in red next to the green fills. No records.
    pub fn give_up(&mut self) {
        if self.locked() {
            return;
        }
        for i in 0..CELLS {
            if !self.original[i] && self.values[i] == 0 {
                self.values[i] = self.solution[i];
                self.given_up_fill[i] = true;
            }
        }
        // Nothing left to revert to.
        self.checkpoint_active = false;
        self.provisional = vec![false; CELLS];
        self.given_up = true;
        self.paused = false;
        self.selected = None;
    }

    /// The clock, driven by the page's frame clock while the game is open and live.
    pub fn tick(&mut self, dt: f64) {
        if !self.busy() {
            self.elapsed += dt;
        }
    }

    /// Full and rule-valid = solved (any valid completion wins, not only the canonical
    /// one). Updates the records.
    fn check_completion(&mut self) {
        if self.complete || self.values.contains(&0) || !self.is_board_valid() {
            return;
        }
        self.complete = true;
        self.selected = None;
        let secs = self.elapsed as u64;
        let slot = &mut self.records.best[self.difficulty.index()];
        self.new_best = *slot == 0 || secs < *slot;
        if self.new_best {
            *slot = secs;
        }
        self.records.solved += 1;
    }

    /// Every row, column, and box holds 1–9 exactly once.
    pub fn is_board_valid(&self) -> bool {
        self.values.iter().all(|&v| (1..=9).contains(&v)) && is_consistent(&self.values)
    }

    pub fn save_state(&self) -> SaveState {
        SaveState {
            values: self.values.clone(),
            original: self.original.clone(),
            solution: self.solution.clone(),
            notes: self.notes.clone(),
            provisional: self.provisional.clone(),
            given_up_fill: self.given_up_fill.clone(),
            notes_mode: self.notes_mode,
            checkpoint_active: self.checkpoint_active,
            checkpoint_values: self.checkpoint_values.clone(),
            checkpoint_notes: self.checkpoint_notes.clone(),
            checkpoint_cursor: self.checkpoint_cursor,
            difficulty: self.difficulty,
            hints_remaining: self.hints_remaining,
            elapsed_secs: self.elapsed as u64,
            complete: self.complete,
            given_up: self.given_up,
            history: self.history.clone(),
            cursor: self.cursor,
        }
    }

    /// Rebuild from a snapshot. A malformed one (wrong lengths, a solution that is not a
    /// Sudoku, a clue that contradicts it) is ignored rather than restoring an unsolvable
    /// board. Returns whether the snapshot was taken.
    pub fn apply_save(&mut self, s: SaveState) -> bool {
        let ok = s.values.len() == CELLS
            && s.original.len() == CELLS
            && s.solution.len() == CELLS
            && s.notes.len() == CELLS
            && s.provisional.len() == CELLS
            && s.given_up_fill.len() == CELLS
            && s.checkpoint_values.len() == CELLS
            && s.checkpoint_notes.len() == CELLS
            && s.cursor <= s.history.len()
            && s.history
                .iter()
                .all(|e| e.i < CELLS && e.peers.iter().all(|p| p.0 < CELLS))
            && s.solution.iter().all(|&v| (1..=9).contains(&v))
            && is_consistent(&s.solution)
            && (0..CELLS).all(|i| !s.original[i] || s.values[i] == s.solution[i]);
        if !ok {
            return false;
        }
        self.values = s.values;
        self.original = s.original;
        self.solution = s.solution;
        self.notes = s.notes;
        self.provisional = s.provisional;
        self.given_up_fill = s.given_up_fill;
        self.notes_mode = s.notes_mode;
        self.checkpoint_active = s.checkpoint_active;
        self.checkpoint_values = s.checkpoint_values;
        self.checkpoint_notes = s.checkpoint_notes;
        self.checkpoint_cursor = s.checkpoint_cursor;
        self.difficulty = s.difficulty;
        self.hints_remaining = s.hints_remaining;
        self.elapsed = s.elapsed_secs as f64;
        self.complete = s.complete;
        self.given_up = s.given_up;
        self.history = s.history;
        self.cursor = s.cursor;
        self.selected = None;
        self.paused = false;
        self.new_best = false;
        true
    }
}

// ---------------------------------------------------------------------------
// Puzzle generation (Faire's scheme): the canonical solution scrambled by digit
// relabeling and thirty random row/column/band/stack swaps, then cells removed
// in 180°-symmetric pairs down to the difficulty's clue count. The win check is
// rule-based, so uniqueness is not required.
// ---------------------------------------------------------------------------

const CANONICAL: [u8; CELLS] = [
    5, 3, 4, 6, 7, 8, 9, 1, 2, //
    6, 7, 2, 1, 9, 5, 3, 4, 8, //
    1, 9, 8, 3, 4, 2, 5, 6, 7, //
    8, 5, 9, 7, 6, 1, 4, 2, 3, //
    4, 2, 6, 8, 5, 3, 7, 9, 1, //
    7, 1, 3, 9, 2, 4, 8, 5, 6, //
    9, 6, 1, 5, 3, 7, 2, 8, 4, //
    2, 8, 7, 4, 1, 9, 6, 3, 5, //
    3, 4, 5, 2, 8, 6, 1, 7, 9,
];

/// No row, column, or box holds the same non-zero digit twice (empty cells skipped).
pub fn is_consistent(grid: &[u8]) -> bool {
    if grid.len() != CELLS {
        return false;
    }
    let group_ok = |cells: [usize; 9]| {
        let mut seen = 0u16;
        for i in cells {
            let v = grid[i];
            if v == 0 {
                continue;
            }
            if v > 9 || seen & (1 << v) != 0 {
                return false;
            }
            seen |= 1 << v;
        }
        true
    };
    (0..9).all(|g| {
        group_ok(std::array::from_fn(|c| idx(g, c)))
            && group_ok(std::array::from_fn(|r| idx(r, g)))
            && group_ok(std::array::from_fn(|k| {
                idx((g / 3) * 3 + k / 3, (g % 3) * 3 + k % 3)
            }))
    })
}

fn generate_solution(rng: &mut Rng) -> Vec<u8> {
    let mut grid = CANONICAL.to_vec();
    // Relabel digits with a random permutation.
    let mut digits: Vec<u8> = (1..=9).collect();
    for i in (1..digits.len()).rev() {
        digits.swap(i, rng.below(i + 1));
    }
    for v in grid.iter_mut() {
        *v = digits[(*v - 1) as usize];
    }
    for _ in 0..30 {
        match rng.below(4) {
            0 => {
                let band = rng.below(3);
                let r1 = rng.below(3);
                let r2 = rng.other(r1);
                swap_rows(&mut grid, band * 3 + r1, band * 3 + r2);
            }
            1 => {
                let stack = rng.below(3);
                let c1 = rng.below(3);
                let c2 = rng.other(c1);
                swap_cols(&mut grid, stack * 3 + c1, stack * 3 + c2);
            }
            2 => {
                let b1 = rng.below(3);
                let b2 = rng.other(b1);
                for k in 0..3 {
                    swap_rows(&mut grid, b1 * 3 + k, b2 * 3 + k);
                }
            }
            _ => {
                let s1 = rng.below(3);
                let s2 = rng.other(s1);
                for k in 0..3 {
                    swap_cols(&mut grid, s1 * 3 + k, s2 * 3 + k);
                }
            }
        }
    }
    grid
}

fn swap_rows(grid: &mut [u8], r1: usize, r2: usize) {
    for c in 0..9 {
        grid.swap(idx(r1, c), idx(r2, c));
    }
}

fn swap_cols(grid: &mut [u8], c1: usize, c2: usize) {
    for r in 0..9 {
        grid.swap(idx(r, c1), idx(r, c2));
    }
}

/// Remove cells in 180°-symmetric pairs until `clues` remain (the count is exact: the last
/// removal skips its mate when one more would undershoot).
fn remove_cells(solution: &[u8], clues: usize, rng: &mut Rng) -> Vec<u8> {
    let mut puzzle = solution.to_vec();
    let mut order: Vec<usize> = (0..CELLS).collect();
    for i in (1..order.len()).rev() {
        order.swap(i, rng.below(i + 1));
    }
    let mut remaining = CELLS;
    for &i in &order {
        if remaining <= clues {
            break;
        }
        if puzzle[i] == 0 {
            continue;
        }
        puzzle[i] = 0;
        remaining -= 1;
        let mate = CELLS - 1 - i;
        if mate != i && puzzle[mate] != 0 && remaining > clues {
            puzzle[mate] = 0;
            remaining -= 1;
        }
    }
    puzzle
}

/// `(puzzle, solution)`. The transformations preserve validity, so the check is defensive;
/// the canonical grid is the fallback so the player never faces an unsolvable board.
fn generate_puzzle(rng: &mut Rng, difficulty: Difficulty) -> (Vec<u8>, Vec<u8>) {
    for _ in 0..5 {
        let solution = generate_solution(rng);
        if is_consistent(&solution) && !solution.contains(&0) {
            let puzzle = remove_cells(&solution, difficulty.clues(), rng);
            if is_consistent(&puzzle) {
                return (puzzle, solution);
            }
        }
    }
    let solution = CANONICAL.to_vec();
    let puzzle = remove_cells(&solution, difficulty.clues(), rng);
    (puzzle, solution)
}

/// mm:ss (or h:mm:ss past an hour) for the HUD and records.
pub fn fmt_time(secs: u64) -> String {
    if secs >= 3600 {
        format!("{}:{:02}:{:02}", secs / 3600, (secs / 60) % 60, secs % 60)
    } else {
        format!("{:02}:{:02}", secs / 60, secs % 60)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn model() -> Model {
        Model::new(0xC0FFEE, Difficulty::Easy)
    }

    /// Solve the whole board via the public input path (selection + place).
    fn solve(m: &mut Model) {
        for i in 0..CELLS {
            if !m.original[i] {
                m.selected = Some(i);
                m.place(m.solution[i]);
            }
        }
    }

    #[test]
    fn generated_puzzle_is_consistent_with_its_solution() {
        for seed in 1..40u64 {
            for d in DIFFICULTIES {
                let m = Model::new(seed, d);
                let mut full = Model::new(1, Difficulty::Easy);
                full.values = m.solution.clone();
                assert!(full.is_board_valid(), "seed {seed}: solution is a Sudoku");
                let clues = m.values.iter().filter(|&&v| v != 0).count();
                assert_eq!(clues, d.clues(), "seed {seed}: exact clue count");
                assert!(is_consistent(&m.values));
                for i in 0..CELLS {
                    assert!(m.values[i] == 0 || m.values[i] == m.solution[i]);
                    assert_eq!(m.original[i], m.values[i] != 0);
                }
            }
        }
    }

    /// dayscript/sudoku.yaml and games.yaml run with `DAY_GAMES_SEED=15` and tap cells 40–42
    /// expecting them empty at Medium. A generator change that fills one breaks the walkthrough,
    /// so it breaks here first.
    #[test]
    fn scripted_seed_keeps_the_walkthrough_cells_empty() {
        let m = Model::new(15, Difficulty::Medium);
        for i in [40usize, 41, 42] {
            assert!(!m.original[i], "cell {i} must be empty for seed 15");
        }
    }

    #[test]
    fn removal_is_symmetric() {
        let m = Model::new(5, Difficulty::Hard);
        // With an even number of removals every hole has its 180° mate, bar the center.
        let asymmetric = (0..CELLS)
            .filter(|&i| i != 40 && (m.values[i] == 0) != (m.values[CELLS - 1 - i] == 0))
            .count();
        assert!(asymmetric <= 1, "at most the final unpaired removal");
    }

    #[test]
    fn place_undo_redo_round_trip_with_peer_notes() {
        let mut m = model();
        let i = (0..CELLS).find(|&i| !m.original[i]).unwrap();
        let j = (0..CELLS)
            .find(|&j| Model::is_peer(i, j) && !m.original[j])
            .unwrap();
        let d = m.solution[i];
        m.selected = Some(j);
        m.notes_mode = true;
        m.place(d);
        m.notes_mode = false;
        assert_ne!(m.notes[j] & (1 << d), 0);

        m.selected = Some(i);
        assert!(m.place(d));
        assert_eq!(m.values[i], d);
        assert_eq!(m.notes[j] & (1 << d), 0, "peer note stripped");

        m.undo();
        assert_eq!(m.values[i], 0);
        assert_ne!(m.notes[j] & (1 << d), 0, "peer note restored");
        m.redo();
        assert_eq!(m.values[i], d);
        assert_eq!(m.notes[j] & (1 << d), 0, "peer note re-stripped");
    }

    #[test]
    fn easy_flags_conflicts_and_locks_exhausted_digits() {
        let mut m = model();
        let empties: Vec<usize> = (0..CELLS).filter(|&i| !m.original[i]).collect();
        let i = empties[0];
        // A digit already present in i's row is a conflict in Easy.
        let row = i / 9;
        let dup = (0..9)
            .map(|c| m.values[idx(row, c)])
            .find(|&v| v != 0)
            .unwrap();
        m.selected = Some(i);
        assert!(m.place(dup));
        assert!(m.is_obvious_mistake(i));
        // Expert never flags.
        let mut e = Model::new(0xC0FFEE, Difficulty::Expert);
        let ei = (0..CELLS).find(|&i| !e.original[i]).unwrap();
        let erow = ei / 9;
        let edup = (0..9)
            .map(|c| e.values[idx(erow, c)])
            .find(|&v| v != 0)
            .unwrap();
        e.selected = Some(ei);
        assert!(e.place(edup));
        assert!(!e.is_obvious_mistake(ei));
        assert!(!e.is_exhausted(edup));
    }

    #[test]
    fn checkpoint_revert_drops_session_and_keeps_prior_undo() {
        let mut m = model();
        let empties: Vec<usize> = (0..CELLS).filter(|&i| !m.original[i]).collect();
        m.selected = Some(empties[0]);
        m.place(m.solution[empties[0]]);
        let before = m.values.clone();

        m.enter_checkpoint();
        m.selected = Some(empties[1]);
        m.place(m.solution[empties[1]]);
        assert!(m.provisional[empties[1]]);
        m.revert_checkpoint();
        assert_eq!(m.values, before);
        assert!(m.can_undo());
        m.undo();
        assert_eq!(m.values[empties[0]], 0);
    }

    #[test]
    fn checkpoint_commit_keeps_values_and_clears_provisional() {
        let mut m = model();
        let i = (0..CELLS).find(|&i| !m.original[i]).unwrap();
        m.enter_checkpoint();
        m.selected = Some(i);
        m.place(m.solution[i]);
        m.commit_checkpoint();
        assert_eq!(m.values[i], m.solution[i]);
        assert!(!m.provisional[i]);
        assert!(!m.can_undo(), "history cleared on commit");
    }

    #[test]
    fn solving_sets_complete_and_records() {
        let mut m = model();
        m.elapsed = 100.0;
        solve(&mut m);
        assert!(m.complete && m.new_best && m.locked());
        assert_eq!(m.records.best[Difficulty::Easy.index()], 100);
        assert_eq!(m.records.solved, 1);
        let records = m.records.clone();
        let mut m2 = Model::new(7, Difficulty::Easy);
        m2.records = records;
        m2.elapsed = 200.0;
        solve(&mut m2);
        assert!(m2.complete && !m2.new_best);
        assert_eq!(m2.records.best[Difficulty::Easy.index()], 100);
        assert_eq!(m2.records.solved, 2);
    }

    #[test]
    fn hint_fills_correct_digit_committed_and_spends_budget() {
        let mut m = Model::new(3, Difficulty::Medium);
        assert_eq!(m.hints_remaining, 3);
        let i = (0..CELLS).find(|&i| !m.original[i]).unwrap();
        m.enter_checkpoint();
        m.selected = Some(i);
        assert!(m.hint());
        assert_eq!(m.values[i], m.solution[i]);
        assert!(!m.provisional[i], "a hint is committed inside a checkpoint");
        assert_eq!(m.hints_remaining, 2);
        // With nothing selected the first empty cell takes the hint.
        m.selected = None;
        assert!(m.hint());
        assert_eq!(m.hints_remaining, 1);
        // Easy is unlimited; Hard grants none.
        let mut e = Model::new(3, Difficulty::Easy);
        for _ in 0..5 {
            assert!(e.hint());
        }
        assert_eq!(e.hints_remaining, -1);
        let h = Model::new(3, Difficulty::Hard);
        assert!(!h.can_hint());
    }

    #[test]
    fn pause_stops_the_clock_and_input() {
        let mut m = model();
        let i = (0..CELLS).find(|&i| !m.original[i]).unwrap();
        m.paused = true;
        m.tick(5.0);
        assert_eq!(m.elapsed, 0.0);
        m.selected = Some(i);
        assert!(!m.place(m.solution[i]));
        m.paused = false;
        m.tick(5.0);
        assert_eq!(m.elapsed, 5.0);
        assert!(m.place(m.solution[i]));
    }

    #[test]
    fn arrows_move_the_selection() {
        let mut m = model();
        m.move_selection(0, 1);
        assert_eq!(m.selected, Some(idx(4, 5)));
        m.move_selection(-9, 0);
        assert_eq!(m.selected, Some(idx(0, 5)));
    }

    #[test]
    fn save_restore_round_trips() {
        let mut m = model();
        let i = (0..CELLS).find(|&i| !m.original[i]).unwrap();
        m.selected = Some(i);
        m.notes_mode = true;
        m.place(3);
        m.notes_mode = false;
        m.elapsed = 42.0;
        let s = m.save_state();
        let json = serde_json::to_string(&s).unwrap();
        let back: SaveState = serde_json::from_str(&json).unwrap();
        let mut m2 = Model::new(99, Difficulty::Hard);
        assert!(m2.apply_save(back));
        assert_eq!(m2.values, m.values);
        assert_eq!(m2.notes, m.notes);
        assert_eq!(m2.difficulty, Difficulty::Easy);
        assert_eq!(m2.elapsed as u64, 42);
        assert!(m2.can_undo());
    }

    #[test]
    fn inconsistent_save_is_rejected() {
        let m = model();
        let mut s = m.save_state();
        // A clue that contradicts the solution.
        let i = (0..CELLS).find(|&i| s.original[i]).unwrap();
        s.values[i] = s.solution[i] % 9 + 1;
        let mut m2 = Model::new(99, Difficulty::Hard);
        assert!(!m2.apply_save(s));
        assert_eq!(m2.difficulty, Difficulty::Hard, "untouched");
    }

    #[test]
    fn give_up_fills_empties_keeps_wrong_entries_and_locks() {
        let mut m = model();
        let empties: Vec<usize> = (0..CELLS).filter(|&i| !m.original[i]).collect();
        let (i, j) = (empties[0], empties[1]);
        m.selected = Some(i);
        m.place(m.solution[i] % 9 + 1); // wrong on purpose
        m.enter_checkpoint();
        m.give_up();
        assert!(m.given_up && m.locked() && !m.checkpoint_active);
        assert_ne!(m.values[i], m.solution[i], "the wrong entry stays");
        assert!(m.is_user_wrong(i));
        assert_eq!(m.values[j], m.solution[j]);
        assert!(m.given_up_fill[j] && !m.given_up_fill[i]);
        assert!(!m.complete, "give up is not a win");
        assert_eq!(m.records.solved, 0);
    }
}
