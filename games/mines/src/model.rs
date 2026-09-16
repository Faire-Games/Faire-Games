//! Mines' rules, free of UI: a board whose mines are laid only once the first tap has landed (so
//! it can never be the one that ends the game), revealing and the cascade it opens, flags,
//! chording a satisfied number, and the records a finished game leaves behind.

use std::collections::VecDeque;

use serde::{Deserialize, Serialize};

/// The three boards on offer.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, Serialize, Deserialize)]
pub enum Difficulty {
    #[default]
    Easy,
    Medium,
    Hard,
}

pub const DIFFICULTIES: [Difficulty; 3] = [Difficulty::Easy, Difficulty::Medium, Difficulty::Hard];

impl Difficulty {
    pub fn index(self) -> usize {
        match self {
            Difficulty::Easy => 0,
            Difficulty::Medium => 1,
            Difficulty::Hard => 2,
        }
    }

    /// The board's short and long side, and its mines. The counts are the difficulty; which way
    /// round they go is [`Difficulty::shape`]'s job, so a phone and a desktop play the same game.
    fn size(self) -> (usize, usize, usize) {
        match self {
            Difficulty::Easy => (9, 9, 10),
            Difficulty::Medium => (10, 15, 25),
            Difficulty::Hard => (12, 20, 55),
        }
    }

    /// Columns and rows for a board with this much room: the long side lies along the window's
    /// long side, so the cells stay as big as the screen allows either way up.
    pub fn shape(self, landscape: bool) -> (usize, usize) {
        let (short, long, _) = self.size();
        if landscape {
            (long, short)
        } else {
            (short, long)
        }
    }

    pub fn mines(self) -> usize {
        self.size().2
    }
}

/// What a cell is showing.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub enum Cell {
    Hidden,
    Flagged,
    Revealed,
}

/// What a tap did: everything the page needs for its sounds, haptics and animations.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Outcome {
    /// Cells uncovered, in the order the cascade reached them.
    pub revealed: Vec<usize>,
    pub flagged: Option<usize>,
    pub unflagged: Option<usize>,
    /// The reveal came from chording a satisfied number.
    pub chorded: bool,
    /// The mine that ended the game.
    pub boom: Option<usize>,
    pub won: bool,
    /// Nothing happened: a tap on an already-revealed blank, or a chord that is not satisfied.
    pub refused: bool,
}

impl Outcome {
    fn refused() -> Outcome {
        Outcome {
            refused: true,
            ..Outcome::default()
        }
    }

    pub fn did_something(&self) -> bool {
        !self.refused
    }
}

/// A small xorshift, so a board is reproducible from its seed.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
}

/// The board and the game on it.
#[derive(Clone, Debug, PartialEq)]
pub struct Board {
    pub cols: usize,
    pub rows: usize,
    pub mines: usize,
    pub mine: Vec<bool>,
    /// Mines touching each cell, once the mines are laid.
    pub near: Vec<u8>,
    pub state: Vec<Cell>,
    /// The mines are laid; before the first tap there are none, which is what keeps it safe.
    pub laid: bool,
    pub flags: usize,
    pub revealed: usize,
    /// The mine that ended the game.
    pub lost_at: Option<usize>,
    pub won: bool,
    pub elapsed: f64,
    seed: u64,
}

impl Board {
    pub fn new(cols: usize, rows: usize, mines: usize, seed: u64) -> Board {
        let n = cols * rows;
        // Room for the safe opening: the first tap and its neighbors never hold a mine.
        let mines = mines.min(n.saturating_sub(9));
        Board {
            cols,
            rows,
            mines,
            mine: vec![false; n],
            near: vec![0; n],
            state: vec![Cell::Hidden; n],
            laid: false,
            flags: 0,
            revealed: 0,
            lost_at: None,
            won: false,
            elapsed: 0.0,
            seed: seed | 1,
        }
    }

    /// How many squares the board holds.
    pub fn cells(&self) -> usize {
        self.cols * self.rows
    }

    pub fn at(&self, col: usize, row: usize) -> usize {
        row * self.cols + col
    }

    pub fn col_row(&self, i: usize) -> (usize, usize) {
        (i % self.cols, i / self.cols)
    }

    /// The up-to-eight cells around `i`.
    pub fn neighbors(&self, i: usize) -> Vec<usize> {
        let (c, r) = self.col_row(i);
        let mut out = Vec::with_capacity(8);
        for dr in -1i64..=1 {
            for dc in -1i64..=1 {
                if dr == 0 && dc == 0 {
                    continue;
                }
                let (nc, nr) = (c as i64 + dc, r as i64 + dr);
                if nc >= 0 && nr >= 0 && (nc as usize) < self.cols && (nr as usize) < self.rows {
                    out.push(nr as usize * self.cols + nc as usize);
                }
            }
        }
        out
    }

    /// Whether the game has started (the first tap landed) and has not finished.
    pub fn live(&self) -> bool {
        self.laid && !self.over()
    }

    pub fn over(&self) -> bool {
        self.won || self.lost_at.is_some()
    }

    /// Mines less flags: what the counter shows, which goes negative when over-flagged.
    pub fn mines_left(&self) -> i64 {
        self.mines as i64 - self.flags as i64
    }

    /// Hidden cells that hold no mine; zero means the board is swept.
    pub fn left_to_find(&self) -> usize {
        self.cells() - self.mines - self.revealed
    }

    pub fn tick(&mut self, dt: f64) {
        if self.live() {
            self.elapsed += dt.max(0.0);
        }
    }

    /// Lay the mines, keeping `safe` and everything around it clear.
    fn lay(&mut self, safe: usize) {
        let clear: Vec<usize> = std::iter::once(safe).chain(self.neighbors(safe)).collect();
        let mut spots: Vec<usize> = (0..self.cells()).filter(|i| !clear.contains(i)).collect();
        let mut rng = Rng(self.seed);
        // Fisher-Yates over the eligible cells, then take the first `mines` of them.
        for i in (1..spots.len()).rev() {
            let j = (rng.next() % (i as u64 + 1)) as usize;
            spots.swap(i, j);
        }
        for &i in spots.iter().take(self.mines) {
            self.mine[i] = true;
        }
        for i in 0..self.cells() {
            self.near[i] = self.neighbors(i).iter().filter(|&&n| self.mine[n]).count() as u8;
        }
        self.laid = true;
    }

    /// Uncover `i`: the first tap lays the mines around it, a blank opens everything it touches,
    /// and a tap on a number that has its flags chords instead.
    pub fn reveal(&mut self, i: usize) -> Outcome {
        if i >= self.cells() || self.over() {
            return Outcome::refused();
        }
        match self.state[i] {
            Cell::Flagged => Outcome::refused(),
            Cell::Revealed => self.chord(i),
            Cell::Hidden => {
                if !self.laid {
                    self.lay(i);
                }
                if self.mine[i] {
                    self.lost_at = Some(i);
                    self.state[i] = Cell::Revealed;
                    return Outcome {
                        boom: Some(i),
                        ..Outcome::default()
                    };
                }
                let mut out = Outcome::default();
                self.cascade(i, &mut out);
                self.check_won(&mut out);
                out
            }
        }
    }

    /// Uncover `from`, and everything a blank opens up, in rings out from it.
    fn cascade(&mut self, from: usize, out: &mut Outcome) {
        let mut queue = VecDeque::from([from]);
        while let Some(i) = queue.pop_front() {
            if self.state[i] != Cell::Hidden || self.mine[i] {
                continue;
            }
            self.state[i] = Cell::Revealed;
            self.revealed += 1;
            out.revealed.push(i);
            if self.near[i] == 0 {
                for n in self.neighbors(i) {
                    if self.state[n] == Cell::Hidden {
                        queue.push_back(n);
                    }
                }
            }
        }
    }

    /// Plant or lift a flag. Flagging before the first tap is allowed; it lays nothing.
    pub fn flag(&mut self, i: usize) -> Outcome {
        if i >= self.cells() || self.over() {
            return Outcome::refused();
        }
        match self.state[i] {
            Cell::Hidden => {
                self.state[i] = Cell::Flagged;
                self.flags += 1;
                Outcome {
                    flagged: Some(i),
                    ..Outcome::default()
                }
            }
            Cell::Flagged => {
                self.state[i] = Cell::Hidden;
                self.flags -= 1;
                Outcome {
                    unflagged: Some(i),
                    ..Outcome::default()
                }
            }
            Cell::Revealed => Outcome::refused(),
        }
    }

    /// A revealed number with exactly its flags around it opens the rest of its neighbors: the
    /// move that makes a big board quick, and the one that ends a game on a misplaced flag.
    pub fn chord(&mut self, i: usize) -> Outcome {
        if self.state[i] != Cell::Revealed || self.near[i] == 0 || self.over() {
            return Outcome::refused();
        }
        let around = self.neighbors(i);
        let flags = around
            .iter()
            .filter(|&&n| self.state[n] == Cell::Flagged)
            .count();
        if flags != self.near[i] as usize {
            return Outcome::refused();
        }
        let mut out = Outcome {
            chorded: true,
            ..Outcome::default()
        };
        for n in around {
            if self.state[n] != Cell::Hidden {
                continue;
            }
            if self.mine[n] {
                self.lost_at = Some(n);
                self.state[n] = Cell::Revealed;
                out.boom = Some(n);
                return out;
            }
            self.cascade(n, &mut out);
        }
        if out.revealed.is_empty() {
            return Outcome::refused();
        }
        self.check_won(&mut out);
        out
    }

    /// Every cell that is not a mine is uncovered: the game is won, and the mines it never had to
    /// touch are flagged for it.
    fn check_won(&mut self, out: &mut Outcome) {
        if self.left_to_find() > 0 {
            return;
        }
        self.won = true;
        out.won = true;
        for i in 0..self.cells() {
            if self.mine[i] && self.state[i] != Cell::Flagged {
                self.state[i] = Cell::Flagged;
                self.flags += 1;
            }
        }
    }

    pub fn save_state(&self, difficulty: Difficulty) -> SaveState {
        SaveState {
            difficulty,
            cols: self.cols,
            rows: self.rows,
            mines: self.mines,
            mine: self.mine.clone(),
            state: self.state.iter().map(|c| *c as u8).collect(),
            laid: self.laid,
            elapsed: self.elapsed,
            seed: self.seed,
        }
    }

    /// Rebuild a saved game, or `None` when the save does not describe a board (a schema change,
    /// or a finished game that should not come back).
    pub fn from_save(s: SaveState) -> Option<(Board, Difficulty)> {
        let n = s.cols.checked_mul(s.rows)?;
        if n == 0 || s.mine.len() != n || s.state.len() != n {
            return None;
        }
        let mut b = Board::new(s.cols, s.rows, s.mines, s.seed);
        b.mine = s.mine;
        b.laid = s.laid;
        b.elapsed = s.elapsed;
        b.state = s
            .state
            .iter()
            .map(|c| match c {
                1 => Cell::Flagged,
                2 => Cell::Revealed,
                _ => Cell::Hidden,
            })
            .collect();
        for i in 0..n {
            b.near[i] = b.neighbors(i).iter().filter(|&&x| b.mine[x]).count() as u8;
        }
        b.flags = b.state.iter().filter(|c| **c == Cell::Flagged).count();
        b.revealed = b.state.iter().filter(|c| **c == Cell::Revealed).count();
        // A saved game is one in progress: a board already won or lost starts over instead.
        if b.state
            .iter()
            .enumerate()
            .any(|(i, c)| *c == Cell::Revealed && b.mine[i])
            || b.left_to_find() == 0
        {
            return None;
        }
        Some((b, s.difficulty))
    }
}

/// The durable whole-board snapshot (gamekit save/restore).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SaveState {
    pub difficulty: Difficulty,
    pub cols: usize,
    pub rows: usize,
    pub mines: usize,
    pub mine: Vec<bool>,
    pub state: Vec<u8>,
    pub laid: bool,
    pub elapsed: f64,
    pub seed: u64,
}

/// Games played and won, and the best time, per difficulty.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Records {
    pub played: [u32; 3],
    pub won: [u32; 3],
    pub best: [Option<f64>; 3],
}

impl Records {
    /// Count a finished game; true when it set the difficulty's best time.
    pub fn record(&mut self, d: Difficulty, won: bool, secs: f64) -> bool {
        let i = d.index();
        self.played[i] += 1;
        if !won {
            return false;
        }
        self.won[i] += 1;
        match self.best[i] {
            Some(b) if b <= secs => false,
            _ => {
                self.best[i] = Some(secs);
                true
            }
        }
    }
}

/// This game's settings: gamekit's switches, the difficulty a new board takes, and whether a tap
/// plants a flag instead of uncovering.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Settings {
    #[serde(default = "on")]
    pub sounds: bool,
    #[serde(default = "on")]
    pub vibrations: bool,
    #[serde(default)]
    pub instructions_shown: bool,
    #[serde(default)]
    pub difficulty: Difficulty,
}

fn on() -> bool {
    true
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            sounds: true,
            vibrations: true,
            instructions_shown: false,
            difficulty: Difficulty::Easy,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn board() -> Board {
        Board::new(9, 9, 10, 7)
    }

    /// Open the board from a corner, which lays the mines.
    fn started() -> Board {
        let mut b = board();
        b.reveal(0);
        b
    }

    /// A revealed number that still has a hidden safe square beside it, so chording it has
    /// something to open; a number whose hidden neighbors are all mines opens nothing.
    fn chordable(b: &Board) -> usize {
        (0..b.cells())
            .find(|&i| {
                b.state[i] == Cell::Revealed
                    && b.near[i] > 0
                    && b.neighbors(i)
                        .iter()
                        .any(|&n| b.state[n] == Cell::Hidden && !b.mine[n])
            })
            .expect("a number with a hidden safe square beside it")
    }

    #[test]
    fn a_board_holds_its_mines_and_counts_them() {
        let b = started();
        assert_eq!(b.mine.iter().filter(|m| **m).count(), 10);
        for i in 0..b.cells() {
            let around = b.neighbors(i).iter().filter(|&&n| b.mine[n]).count();
            assert_eq!(b.near[i] as usize, around, "cell {i}");
        }
    }

    #[test]
    fn the_first_tap_is_safe_and_opens_a_clearing() {
        for seed in 1..40u64 {
            let mut b = Board::new(9, 9, 10, seed);
            let out = b.reveal(b.at(4, 4));
            assert!(
                out.boom.is_none(),
                "seed {seed} put a mine under the first tap"
            );
            // Its neighbors are clear too, so the first tap always opens more than one cell.
            assert!(
                out.revealed.len() >= 9,
                "seed {seed}: {} cells",
                out.revealed.len()
            );
        }
    }

    #[test]
    fn mines_stay_off_the_first_tap_and_its_neighbors() {
        let mut b = Board::new(5, 5, 16, 3);
        let safe = b.at(2, 2);
        b.reveal(safe);
        for i in std::iter::once(safe).chain(b.neighbors(safe)) {
            assert!(!b.mine[i], "cell {i} under the opening");
        }
        assert_eq!(b.mine.iter().filter(|m| **m).count(), 16);
    }

    #[test]
    fn a_board_with_no_room_for_its_mines_takes_what_fits() {
        let b = Board::new(3, 3, 20, 1);
        assert_eq!(b.mines, 0, "a 3x3 is all opening");
    }

    #[test]
    fn a_blank_opens_its_whole_region_and_stops_at_the_numbers() {
        let mut b = started();
        let out = b.reveal(0);
        assert!(out.refused, "tapping a revealed blank again does nothing");
        // Every revealed blank has all of its neighbors revealed; every revealed number does not
        // have to.
        for i in 0..b.cells() {
            if b.state[i] == Cell::Revealed && b.near[i] == 0 {
                for n in b.neighbors(i) {
                    assert_eq!(b.state[n], Cell::Revealed, "{n} beside blank {i}");
                }
            }
        }
        assert!(b.state.contains(&Cell::Hidden), "not the whole board");
    }

    #[test]
    fn a_mine_ends_the_game() {
        let mut b = started();
        let mine = (0..b.cells()).find(|&i| b.mine[i]).unwrap();
        let out = b.reveal(mine);
        assert_eq!(out.boom, Some(mine));
        assert!(b.over() && !b.won);
        assert!(b.reveal(0).refused, "the board is finished");
        assert!(b.flag(1).refused);
    }

    #[test]
    fn flags_toggle_and_hold_a_cell_shut() {
        let mut b = started();
        let hidden = (0..b.cells())
            .find(|&i| b.state[i] == Cell::Hidden)
            .unwrap();
        assert_eq!(b.flag(hidden).flagged, Some(hidden));
        assert_eq!(b.mines_left(), 9);
        assert!(b.reveal(hidden).refused, "a flagged cell does not open");
        assert_eq!(b.flag(hidden).unflagged, Some(hidden));
        assert_eq!(b.mines_left(), 10);
        assert!(b.flag(0).refused, "a revealed cell cannot be flagged");
    }

    #[test]
    fn flagging_before_the_first_tap_lays_nothing() {
        let mut b = board();
        assert_eq!(b.flag(0).flagged, Some(0));
        assert!(!b.laid, "the mines wait for the first reveal");
        b.flag(0);
        let out = b.reveal(0);
        assert!(out.boom.is_none() && b.laid);
    }

    #[test]
    fn chording_opens_the_rest_once_the_flags_match() {
        let mut b = started();
        // A revealed number whose mines are all flagged.
        let numbered = chordable(&b);
        assert!(b.chord(numbered).refused, "no flags yet");
        for n in b.neighbors(numbered) {
            if b.mine[n] {
                b.flag(n);
            }
        }
        let out = b.chord(numbered);
        assert!(out.chorded && !out.revealed.is_empty() && out.boom.is_none());
        assert!(b.chord(numbered).refused, "nothing left to open");
    }

    #[test]
    fn chording_on_a_wrong_flag_ends_the_game() {
        // The first board with a revealed 1 that still has both a hidden mine and a hidden safe
        // square beside it: flag the safe one instead, and chording opens the mine.
        let mut tried = 0;
        for seed in 1..60u64 {
            let mut b = Board::new(9, 9, 10, seed);
            b.reveal(b.at(4, 4));
            let Some((numbered, wrong)) = (0..b.cells()).find_map(|i| {
                if b.state[i] != Cell::Revealed || b.near[i] != 1 {
                    return None;
                }
                let around = b.neighbors(i);
                let mine = around
                    .iter()
                    .any(|&n| b.mine[n] && b.state[n] == Cell::Hidden);
                let safe = around
                    .iter()
                    .find(|&&n| !b.mine[n] && b.state[n] == Cell::Hidden)?;
                mine.then_some((i, *safe))
            }) else {
                continue;
            };
            b.flag(wrong);
            let out = b.chord(numbered);
            assert!(out.boom.is_some(), "seed {seed}: the chord opened the mine");
            assert!(b.over() && !b.won);
            tried += 1;
            if tried == 3 {
                return;
            }
        }
        panic!("no board offered a 1 with a hidden mine and a hidden safe square");
    }

    #[test]
    fn tapping_a_number_chords_it() {
        let mut b = started();
        let numbered = chordable(&b);
        for n in b.neighbors(numbered) {
            if b.mine[n] {
                b.flag(n);
            }
        }
        let out = b.reveal(numbered);
        assert!(out.chorded, "a tap on a satisfied number chords");
    }

    #[test]
    fn sweeping_every_safe_cell_wins_and_flags_the_rest() {
        let mut b = started();
        for i in 0..b.cells() {
            if !b.mine[i] {
                b.reveal(i);
            }
        }
        assert!(b.won && b.lost_at.is_none());
        assert_eq!(b.left_to_find(), 0);
        assert_eq!(b.mines_left(), 0, "the mines it never touched are flagged");
        assert!(b.state.iter().filter(|c| **c == Cell::Flagged).count() == b.mines);
    }

    #[test]
    fn the_clock_runs_only_while_the_game_is_live() {
        let mut b = board();
        b.tick(1.0);
        assert_eq!(b.elapsed, 0.0, "before the first tap");
        b.reveal(0);
        b.tick(1.5);
        assert_eq!(b.elapsed, 1.5);
        let mine = (0..b.cells()).find(|&i| b.mine[i]).unwrap();
        b.reveal(mine);
        b.tick(1.0);
        assert_eq!(b.elapsed, 1.5, "after it ends");
    }

    #[test]
    fn a_seed_lays_the_same_board_twice() {
        let mut a = Board::new(9, 9, 10, 99);
        let mut b = Board::new(9, 9, 10, 99);
        a.reveal(a.at(4, 4));
        b.reveal(b.at(4, 4));
        assert_eq!(a.mine, b.mine);
    }

    #[test]
    fn a_game_in_progress_comes_back_from_its_save() {
        let mut b = started();
        b.flag(b.cells() - 1);
        b.tick(12.0);
        let (back, d) = Board::from_save(b.save_state(Difficulty::Medium)).expect("restored");
        assert_eq!(d, Difficulty::Medium);
        assert_eq!(back.state, b.state);
        assert_eq!(back.near, b.near);
        assert_eq!(back.flags, b.flags);
        assert_eq!(back.revealed, b.revealed);
        assert_eq!(back.elapsed, 12.0);
    }

    #[test]
    fn a_finished_game_does_not_come_back() {
        let mut lost = started();
        let mine = (0..lost.cells()).find(|&i| lost.mine[i]).unwrap();
        lost.reveal(mine);
        assert!(Board::from_save(lost.save_state(Difficulty::Easy)).is_none());

        let mut won = started();
        for i in 0..won.cells() {
            if !won.mine[i] {
                won.reveal(i);
            }
        }
        assert!(Board::from_save(won.save_state(Difficulty::Easy)).is_none());
    }

    #[test]
    fn the_board_turns_with_the_window() {
        for d in DIFFICULTIES {
            let (pc, pr) = d.shape(false);
            let (lc, lr) = d.shape(true);
            assert_eq!((pc, pr), (lr, lc), "{d:?} holds the same cells either way");
            assert!(pr >= pc, "{d:?} stands tall in portrait");
            assert!(pc * pr > d.mines(), "{d:?} has room for its mines");
            // Dense enough to be a puzzle, sparse enough to be fair.
            let density = d.mines() as f64 / (pc * pr) as f64;
            assert!((0.1..0.25).contains(&density), "{d:?}: {density}");
        }
    }

    #[test]
    fn records_keep_the_best_time_per_difficulty() {
        let mut r = Records::default();
        assert!(
            !r.record(Difficulty::Easy, false, 30.0),
            "a loss sets no best"
        );
        assert!(r.record(Difficulty::Easy, true, 40.0));
        assert!(!r.record(Difficulty::Easy, true, 50.0));
        assert!(r.record(Difficulty::Easy, true, 20.0));
        assert_eq!(r.best[0], Some(20.0));
        assert_eq!((r.played[0], r.won[0]), (4, 3));
        assert_eq!(r.best[1], None, "another difficulty is untouched");
    }
}
