//! The Sudoku game state — board, notes, cursor-based undo/redo, checkpoints, hints,
//! records — mirroring Faire-Games' SudokuModel. Pure logic, no UI: everything here is
//! host-testable with `cargo test`.

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
    /// Starting hint budget; `None` = unlimited (Easy).
    pub fn hints(self) -> Option<i32> {
        match self {
            Difficulty::Easy => None,
            Difficulty::Medium => Some(3),
            Difficulty::Hard | Difficulty::Expert => Some(0),
        }
    }
    /// Expert hides the same-number highlight.
    pub fn highlights_same_digit(self) -> bool {
        !matches!(self, Difficulty::Expert)
    }
    pub fn index(self) -> usize {
        match self {
            Difficulty::Easy => 0,
            Difficulty::Medium => 1,
            Difficulty::Hard => 2,
            Difficulty::Expert => 3,
        }
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

/// Per-difficulty best times (seconds; 0 = none yet) and the total solved count.
#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Records {
    pub best: [u64; 4],
    pub solved: u64,
}

/// The durable whole-game snapshot (gamekit save/restore).
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
    pub records: Records,
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
    /// The just-finished solve set a new best time (for the solved banner).
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
        self.solution = generate_solution(&mut self.rng);
        self.values = remove_cells(&self.solution, difficulty.clues(), &mut self.rng);
        self.original = self.values.iter().map(|&v| v != 0).collect();
        self.notes = vec![0; CELLS];
        self.provisional = vec![false; CELLS];
        self.given_up_fill = vec![false; CELLS];
        self.selected = None;
        self.notes_mode = false;
        self.checkpoint_active = false;
        self.checkpoint_cursor = 0;
        self.hints_remaining = difficulty.hints().unwrap_or(-1);
        self.elapsed = 0.0;
        self.complete = false;
        self.given_up = false;
        self.new_best = false;
        self.history.clear();
        self.cursor = 0;
    }

    /// Input is locked once the game ended (solved or given up).
    pub fn locked(&self) -> bool {
        self.complete || self.given_up
    }

    pub fn can_undo(&self) -> bool {
        self.cursor > 0 && !self.locked()
    }
    pub fn can_redo(&self) -> bool {
        self.cursor < self.history.len() && !self.locked()
    }
    pub fn can_hint(&self) -> bool {
        !self.locked() && self.hints_remaining != 0
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

    /// How many of digit `d` are placed (keypad dimming: 9 placed = done).
    pub fn placed_count(&self, d: u8) -> usize {
        self.values.iter().filter(|&&v| v == d).count()
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

    /// Enter a digit (or toggle a note) into the selected cell — Faire's placeDigit.
    /// Returns true when something changed.
    pub fn place(&mut self, digit: u8) -> bool {
        let Some(i) = self.selected else { return false };
        if self.locked() || self.original[i] || !(1..=9).contains(&digit) {
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
        self.values[i] = digit;
        self.notes[i] = 0;
        self.provisional[i] = self.checkpoint_active;
        // Strip the digit from peer pencil marks (recorded so undo restores them).
        // Done whether or not the guess is right, so the side effect reveals nothing.
        let mut peers = Vec::new();
        for j in 0..CELLS {
            if Self::is_peer(i, j) && self.notes[j] & (1 << digit) != 0 {
                let before = self.notes[j];
                self.notes[j] &= !(1 << digit);
                peers.push((j, before, self.notes[j]));
            }
        }
        self.push_history(i, old, peers);
        self.check_completion();
        true
    }

    /// Clear the selected cell's value and notes.
    pub fn erase(&mut self) -> bool {
        let Some(i) = self.selected else { return false };
        if self.locked() || self.original[i] || (self.values[i] == 0 && self.notes[i] == 0) {
            return false;
        }
        let old = self.snap(i);
        self.values[i] = 0;
        self.notes[i] = 0;
        self.provisional[i] = false;
        self.push_history(i, old, Vec::new());
        true
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

    /// Fill the correct digit into the selected cell (or the first empty one).
    pub fn hint(&mut self) -> bool {
        if !self.can_hint() {
            return false;
        }
        let target = match self.selected {
            Some(i) if !self.original[i] && self.values[i] != self.solution[i] => Some(i),
            _ => (0..CELLS).find(|&i| self.values[i] == 0),
        };
        let Some(i) = target else { return false };
        self.selected = Some(i);
        let sol = self.solution[i];
        // A hint is an ordinary (undoable) placement of the correct digit.
        let prev_notes_mode = self.notes_mode;
        self.notes_mode = false;
        // `place` toggles an equal value off — clear first if the cell holds a wrong digit.
        if self.values[i] != 0 {
            self.erase();
        }
        let placed = self.place(sol);
        self.notes_mode = prev_notes_mode;
        if placed && self.hints_remaining > 0 {
            self.hints_remaining -= 1;
        }
        placed
    }

    /// Bookmark the current position: later edits render provisional until the checkpoint
    /// is committed (keep them) or reverted (drop them). Entering drops the redo tail.
    pub fn enter_checkpoint(&mut self) {
        if self.locked() || self.checkpoint_active {
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

    /// Reveal the solution and lock the board. No records.
    pub fn give_up(&mut self) {
        if self.locked() {
            return;
        }
        for i in 0..CELLS {
            if self.values[i] != self.solution[i] {
                self.values[i] = self.solution[i];
                self.given_up_fill[i] = true;
            }
        }
        self.notes = vec![0; CELLS];
        self.given_up = true;
        self.selected = None;
    }

    /// The clock, driven by the page's frame clock while the game is open and live.
    pub fn tick(&mut self, dt: f64) {
        if !self.locked() {
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
        let group_ok = |cells: &[usize]| {
            let mut seen = 0u16;
            for &i in cells {
                let v = self.values[i];
                if v == 0 || seen & (1 << v) != 0 {
                    return false;
                }
                seen |= 1 << v;
            }
            true
        };
        for g in 0..9 {
            let row: Vec<usize> = (0..9).map(|c| idx(g, c)).collect();
            let col: Vec<usize> = (0..9).map(|r| idx(r, g)).collect();
            let boxc: Vec<usize> = (0..9)
                .map(|k| idx((g / 3) * 3 + k / 3, (g % 3) * 3 + k % 3))
                .collect();
            if !group_ok(&row) || !group_ok(&col) || !group_ok(&boxc) {
                return false;
            }
        }
        true
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
            records: self.records.clone(),
        }
    }

    /// Rebuild from a snapshot; a malformed one (wrong lengths) is ignored.
    pub fn apply_save(&mut self, s: SaveState) {
        let ok = s.values.len() == CELLS
            && s.original.len() == CELLS
            && s.solution.len() == CELLS
            && s.notes.len() == CELLS
            && s.provisional.len() == CELLS
            && s.given_up_fill.len() == CELLS
            && s.checkpoint_values.len() == CELLS
            && s.checkpoint_notes.len() == CELLS
            && s.cursor <= s.history.len();
        if !ok {
            self.records = s.records; // keep the records even from a bad board
            return;
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
        self.records = s.records;
        self.selected = None;
        self.new_best = false;
    }
}

// ---------------------------------------------------------------------------
// Puzzle generation (Faire's scheme): a base pattern scrambled by digit
// relabeling and row/column/band/stack swaps, then cells removed to the
// difficulty's clue count. The win check is rule-based, so uniqueness is not
// required.
// ---------------------------------------------------------------------------

fn generate_solution(rng: &mut Rng) -> Vec<u8> {
    // Base pattern: (r*3 + r/3 + c) % 9 + 1 is always a valid solution.
    let mut grid: Vec<u8> = (0..CELLS)
        .map(|i| {
            let (r, c) = (i / 9, i % 9);
            ((r * 3 + r / 3 + c) % 9 + 1) as u8
        })
        .collect();
    // Relabel digits with a random permutation.
    let mut digits: Vec<u8> = (1..=9).collect();
    for i in (1..digits.len()).rev() {
        digits.swap(i, rng.below(i + 1));
    }
    for v in grid.iter_mut() {
        *v = digits[(*v - 1) as usize];
    }
    // Swap rows within each band, columns within each stack, whole bands, whole stacks.
    for band in 0..3 {
        let (r1, r2) = (band * 3 + rng.below(3), band * 3 + rng.below(3));
        swap_rows(&mut grid, r1, r2);
    }
    for stack in 0..3 {
        let (c1, c2) = (stack * 3 + rng.below(3), stack * 3 + rng.below(3));
        swap_cols(&mut grid, c1, c2);
    }
    let (b1, b2) = (rng.below(3), rng.below(3));
    for k in 0..3 {
        swap_rows(&mut grid, b1 * 3 + k, b2 * 3 + k);
    }
    let (s1, s2) = (rng.below(3), rng.below(3));
    for k in 0..3 {
        swap_cols(&mut grid, s1 * 3 + k, s2 * 3 + k);
    }
    grid
}

fn swap_rows(grid: &mut [u8], r1: usize, r2: usize) {
    if r1 == r2 {
        return;
    }
    for c in 0..9 {
        grid.swap(idx(r1, c), idx(r2, c));
    }
}

fn swap_cols(grid: &mut [u8], c1: usize, c2: usize) {
    if c1 == c2 {
        return;
    }
    for r in 0..9 {
        grid.swap(idx(r, c1), idx(r, c2));
    }
}

fn remove_cells(solution: &[u8], clues: usize, rng: &mut Rng) -> Vec<u8> {
    let mut puzzle = solution.to_vec();
    let mut order: Vec<usize> = (0..CELLS).collect();
    for i in (1..order.len()).rev() {
        order.swap(i, rng.below(i + 1));
    }
    for &i in order.iter().take(CELLS.saturating_sub(clues)) {
        puzzle[i] = 0;
    }
    puzzle
}

/// mm:ss (or h:mm:ss past an hour) for the HUD and records.
pub fn fmt_time(secs: u64) -> String {
    if secs >= 3600 {
        format!("{}:{:02}:{:02}", secs / 3600, (secs / 60) % 60, secs % 60)
    } else {
        format!("{}:{:02}", secs / 60, secs % 60)
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
        let m = model();
        // The solution is rule-valid.
        let mut full = Model::new(1, Difficulty::Easy);
        full.values = m.solution.clone();
        assert!(full.is_board_valid());
        // The puzzle keeps the difficulty's clue count, all from the solution.
        let clues = m.values.iter().filter(|&&v| v != 0).count();
        assert_eq!(clues, Difficulty::Easy.clues());
        for i in 0..CELLS {
            assert!(m.values[i] == 0 || m.values[i] == m.solution[i]);
            assert_eq!(m.original[i], m.values[i] != 0);
        }
    }

    #[test]
    fn place_undo_redo_round_trip_with_peer_notes() {
        let mut m = model();
        let i = (0..CELLS).find(|&i| !m.original[i]).unwrap();
        // A peer of i notes the digit we are about to place.
        let j = (0..CELLS)
            .find(|&j| Model::is_peer(i, j) && !m.original[j])
            .unwrap();
        let d = m.solution[i];
        m.selected = Some(j);
        m.notes_mode = true;
        m.place(d); // note d in the peer
        m.notes_mode = false;
        assert_ne!(m.notes[j] & (1 << d), 0);

        m.selected = Some(i);
        assert!(m.place(d));
        assert_eq!(m.values[i], d);
        assert_eq!(m.notes[j] & (1 << d), 0, "peer note stripped");

        m.undo(); // un-place
        assert_eq!(m.values[i], 0);
        assert_ne!(m.notes[j] & (1 << d), 0, "peer note restored");
        m.redo();
        assert_eq!(m.values[i], d);
        assert_eq!(m.notes[j] & (1 << d), 0, "peer note re-stripped");
    }

    #[test]
    fn checkpoint_revert_drops_session_and_keeps_prior_undo() {
        let mut m = model();
        let empties: Vec<usize> = (0..CELLS).filter(|&i| !m.original[i]).collect();
        m.selected = Some(empties[0]);
        m.place(m.solution[empties[0]]); // pre-checkpoint move
        let before = m.values.clone();

        m.enter_checkpoint();
        m.selected = Some(empties[1]);
        m.place(m.solution[empties[1]]);
        assert!(
            m.provisional[empties[1]],
            "in-checkpoint entry is provisional"
        );
        m.revert_checkpoint();
        assert_eq!(m.values, before, "checkpoint session dropped");
        assert!(m.can_undo(), "pre-checkpoint move still undoable");
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
        assert!(m.complete);
        assert!(m.new_best);
        assert_eq!(m.records.best[Difficulty::Easy.index()], 100);
        assert_eq!(m.records.solved, 1);
        assert!(m.locked());
        // A slower later solve does not beat the record.
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
    fn hint_fills_correct_digit_and_spends_budget() {
        let mut m = Model::new(3, Difficulty::Medium);
        assert_eq!(m.hints_remaining, 3);
        let i = (0..CELLS).find(|&i| !m.original[i]).unwrap();
        m.selected = Some(i);
        assert!(m.hint());
        assert_eq!(m.values[i], m.solution[i]);
        assert_eq!(m.hints_remaining, 2);
        // Hard grants none.
        let mut h = Model::new(3, Difficulty::Hard);
        assert!(!m.locked());
        assert!(!h.can_hint());
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
        m2.apply_save(back);
        assert_eq!(m2.values, m.values);
        assert_eq!(m2.notes, m.notes);
        assert_eq!(m2.difficulty, Difficulty::Easy);
        assert_eq!(m2.elapsed as u64, 42);
        assert!(m2.can_undo());
    }

    #[test]
    fn give_up_reveals_and_locks() {
        let mut m = model();
        m.give_up();
        assert!(m.given_up && m.locked());
        assert_eq!(m.values, m.solution);
        assert!(m.given_up_fill.iter().any(|&f| f));
        assert!(!m.complete, "give up is not a win");
        assert_eq!(m.records.solved, 0);
    }
}
