//! The Block Blast rules, with no UI in them: the 8×8 board, the three-piece tray, placement,
//! simultaneous row-and-column clears, scoring with combo multipliers and the perfect-clear
//! bonus, the difficulty-controlled piece generator, game-over detection, and the save state.
//! lib.rs draws and animates what [`Model::place`] reports.

use serde::{Deserialize, Serialize};

/// The board is `N` × `N` cells.
pub const N: usize = 8;
pub const CELLS: usize = N * N;
/// The block palette size (lib.rs owns the colors).
pub const COLORS: u8 = 8;
/// Pieces offered at a time.
pub const TRAY: usize = 3;

pub const POINTS_PER_CELL: i64 = 10;
/// Line points grow with the square of the lines a placement clears: 100, 400, 900, …
pub const POINTS_PER_LINE: i64 = 100;
/// Emptying the whole board.
pub const PERFECT_BONUS: i64 = 5000;
/// A combo survives placements that clear nothing, up to this many in a row: the third
/// clearless placement ends it.
pub const COMBO_GRACE: u32 = 3;
/// Placements the solvability search may try per candidate set. A search that runs out answers
/// "unknown", which the generator treats as solvable: running out only happens on roomy boards.
const SEARCH_BUDGET: u32 = 20_000;

/// A piece shape: its cells as `(row, col)` offsets from the top-left corner. Pieces never
/// rotate; each orientation is its own shape.
pub struct Shape {
    /// Stable name, used by the save state.
    pub id: &'static str,
    pub cells: &'static [(u8, u8)],
}

impl Shape {
    pub fn width(&self) -> usize {
        self.cells.iter().map(|c| c.1 as usize).max().unwrap_or(0) + 1
    }
    pub fn height(&self) -> usize {
        self.cells.iter().map(|c| c.0 as usize).max().unwrap_or(0) + 1
    }
    /// Cells in the shape.
    pub fn size(&self) -> usize {
        self.cells.len()
    }
}

/// Every shape the generator draws from (Faire-Games' 29, plus the four 3×3 corners).
pub const SHAPES: &[Shape] = &[
    Shape {
        id: "dot",
        cells: &[(0, 0)],
    },
    Shape {
        id: "h2",
        cells: &[(0, 0), (0, 1)],
    },
    Shape {
        id: "h3",
        cells: &[(0, 0), (0, 1), (0, 2)],
    },
    Shape {
        id: "h4",
        cells: &[(0, 0), (0, 1), (0, 2), (0, 3)],
    },
    Shape {
        id: "h5",
        cells: &[(0, 0), (0, 1), (0, 2), (0, 3), (0, 4)],
    },
    Shape {
        id: "v2",
        cells: &[(0, 0), (1, 0)],
    },
    Shape {
        id: "v3",
        cells: &[(0, 0), (1, 0), (2, 0)],
    },
    Shape {
        id: "v4",
        cells: &[(0, 0), (1, 0), (2, 0), (3, 0)],
    },
    Shape {
        id: "v5",
        cells: &[(0, 0), (1, 0), (2, 0), (3, 0), (4, 0)],
    },
    Shape {
        id: "sq2",
        cells: &[(0, 0), (0, 1), (1, 0), (1, 1)],
    },
    Shape {
        id: "sq3",
        cells: &[
            (0, 0),
            (0, 1),
            (0, 2),
            (1, 0),
            (1, 1),
            (1, 2),
            (2, 0),
            (2, 1),
            (2, 2),
        ],
    },
    Shape {
        id: "L_bl",
        cells: &[(0, 0), (1, 0), (1, 1)],
    },
    Shape {
        id: "L_br",
        cells: &[(0, 1), (1, 0), (1, 1)],
    },
    Shape {
        id: "L_tl",
        cells: &[(0, 0), (0, 1), (1, 0)],
    },
    Shape {
        id: "L_tr",
        cells: &[(0, 0), (0, 1), (1, 1)],
    },
    Shape {
        id: "L23_bl",
        cells: &[(0, 0), (1, 0), (2, 0), (2, 1)],
    },
    Shape {
        id: "L23_br",
        cells: &[(0, 1), (1, 1), (2, 0), (2, 1)],
    },
    Shape {
        id: "L23_tl",
        cells: &[(0, 0), (0, 1), (1, 0), (2, 0)],
    },
    Shape {
        id: "L23_tr",
        cells: &[(0, 0), (0, 1), (1, 1), (2, 1)],
    },
    Shape {
        id: "L33_bl",
        cells: &[(0, 0), (1, 0), (2, 0), (2, 1), (2, 2)],
    },
    Shape {
        id: "L33_br",
        cells: &[(0, 2), (1, 2), (2, 0), (2, 1), (2, 2)],
    },
    Shape {
        id: "L33_tl",
        cells: &[(0, 0), (0, 1), (0, 2), (1, 0), (2, 0)],
    },
    Shape {
        id: "L33_tr",
        cells: &[(0, 0), (0, 1), (0, 2), (1, 2), (2, 2)],
    },
    Shape {
        id: "rect2x3",
        cells: &[(0, 0), (0, 1), (1, 0), (1, 1), (2, 0), (2, 1)],
    },
    Shape {
        id: "rect3x2",
        cells: &[(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2)],
    },
    Shape {
        id: "T_up",
        cells: &[(0, 0), (0, 1), (0, 2), (1, 1)],
    },
    Shape {
        id: "T_dn",
        cells: &[(0, 1), (1, 0), (1, 1), (1, 2)],
    },
    Shape {
        id: "T_lt",
        cells: &[(0, 0), (1, 0), (1, 1), (2, 0)],
    },
    Shape {
        id: "T_rt",
        cells: &[(0, 1), (1, 0), (1, 1), (2, 1)],
    },
    Shape {
        id: "S_h",
        cells: &[(0, 1), (0, 2), (1, 0), (1, 1)],
    },
    Shape {
        id: "Z_h",
        cells: &[(0, 0), (0, 1), (1, 1), (1, 2)],
    },
    Shape {
        id: "S_v",
        cells: &[(0, 0), (1, 0), (1, 1), (2, 1)],
    },
    Shape {
        id: "Z_v",
        cells: &[(0, 1), (1, 0), (1, 1), (2, 0)],
    },
];

/// A shape in a color, as the tray offers it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Piece {
    /// Index into [`SHAPES`].
    pub shape: usize,
    /// Palette index, below [`COLORS`].
    pub color: u8,
}

impl Piece {
    pub fn shape(&self) -> &'static Shape {
        &SHAPES[self.shape]
    }
}

/// The board: a color per cell, row-major, `None` where empty.
pub type Grid = [Option<u8>; CELLS];

pub fn idx(row: usize, col: usize) -> usize {
    row * N + col
}

/// Whether `shape` lies inside the board with its top-left corner at `(row, col)`.
pub fn in_bounds(shape: &Shape, row: i32, col: i32) -> bool {
    row >= 0 && col >= 0 && row as usize + shape.height() <= N && col as usize + shape.width() <= N
}

/// Whether `shape` fits at `(row, col)`: inside the board and on empty cells only.
pub fn fits(grid: &Grid, shape: &Shape, row: i32, col: i32) -> bool {
    in_bounds(shape, row, col)
        && shape.cells.iter().all(|&(r, c)| {
            grid[idx(row as usize + r as usize, col as usize + c as usize)].is_none()
        })
}

/// Whether `shape` fits anywhere on the board.
pub fn fits_anywhere(grid: &Grid, shape: &Shape) -> bool {
    (0..=N - shape.height())
        .any(|r| (0..=N - shape.width()).any(|c| fits(grid, shape, r as i32, c as i32)))
}

fn stamp(grid: &mut Grid, shape: &Shape, row: usize, col: usize, color: u8) {
    for &(r, c) in shape.cells {
        grid[idx(row + r as usize, col + c as usize)] = Some(color);
    }
}

/// The full rows and full columns, each in ascending order.
pub fn full_lines(grid: &Grid) -> (Vec<usize>, Vec<usize>) {
    let rows = (0..N)
        .filter(|&r| (0..N).all(|c| grid[idx(r, c)].is_some()))
        .collect();
    let cols = (0..N)
        .filter(|&c| (0..N).all(|r| grid[idx(r, c)].is_some()))
        .collect();
    (rows, cols)
}

/// Empty every cell in `rows` and `cols` at once, so a cell where a full row crosses a full
/// column is cleared once. Returns the emptied cells with their colors, row-major.
fn clear_lines(grid: &mut Grid, rows: &[usize], cols: &[usize]) -> Vec<(usize, u8)> {
    let mut cleared = Vec::new();
    for (i, cell) in grid.iter_mut().enumerate() {
        if (rows.contains(&(i / N)) || cols.contains(&(i % N)))
            && let Some(color) = cell.take()
        {
            cleared.push((i, color));
        }
    }
    cleared
}

/// The points one placement earns: 10 a cell, 100 × lines², the whole multiplied by the combo
/// streak's multiplier (×1 through ×4 in half steps), plus the perfect-clear bonus.
pub fn move_score(cells: usize, lines: usize, combo: u32, perfect: bool) -> i64 {
    let base = cells as i64 * POINTS_PER_CELL + (lines * lines) as i64 * POINTS_PER_LINE;
    // In halves, so the ×1.5 steps stay integral (`base` is always a multiple of 10).
    let halves = match combo {
        0 | 1 => 2,
        2 => 3,
        3 => 4,
        4 => 5,
        5 => 6,
        6 => 7,
        _ => 8,
    };
    base * halves / 2 + if perfect { PERFECT_BONUS } else { 0 }
}

/// The three rule sets: how hard the generator works to hand out a tray that fits.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, Serialize, Deserialize)]
pub enum Difficulty {
    /// Every tray can be placed in full; a set that fails the check is rebuilt piece by piece.
    Easy,
    /// Up to ten tries for a set that fits, then whatever came up.
    #[default]
    Normal,
    /// Pure chance.
    Hard,
}

pub const DIFFICULTIES: [Difficulty; 3] = [Difficulty::Easy, Difficulty::Normal, Difficulty::Hard];

impl Difficulty {
    /// Random sets the generator tries before its fallback.
    fn attempts(self) -> usize {
        match self {
            Difficulty::Easy => 20,
            Difficulty::Normal => 10,
            Difficulty::Hard => 0,
        }
    }
}

/// Everything one placement did: what lib.rs needs to animate it, score it on screen, and
/// pick the haptics.
#[derive(Clone, Debug)]
pub struct Placement {
    /// The cells the piece filled.
    pub cells: Vec<usize>,
    pub rows: Vec<usize>,
    pub cols: Vec<usize>,
    /// The cells the clears emptied, with the color each had (the piece's own included).
    pub cleared: Vec<(usize, u8)>,
    pub gain: i64,
    /// The combo streak after this placement (0 when it has no combo running).
    pub combo: u32,
    pub perfect: bool,
    /// A fresh tray was dealt because this placement used the last piece.
    pub refilled: bool,
    pub game_over: bool,
}

impl Placement {
    pub fn lines(&self) -> usize {
        self.rows.len() + self.cols.len()
    }

    /// How big the moment is, 0 (no clear) to 6 (the board emptied): the banner, shake,
    /// confetti and haptics all scale from it.
    pub fn tier(&self) -> u8 {
        let (lines, combo) = (self.lines(), self.combo);
        if lines == 0 {
            0
        } else if self.perfect {
            6
        } else if combo >= 7 || lines >= 5 {
            5
        } else if combo >= 5 || lines >= 4 {
            4
        } else if combo >= 3 || lines >= 3 {
            3
        } else if combo >= 2 || lines >= 2 {
            2
        } else {
            1
        }
    }
}

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
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

pub struct Model {
    pub grid: Grid,
    pub tray: [Option<Piece>; TRAY],
    pub score: i64,
    pub best: i64,
    /// Consecutive clearing placements, allowing for [`COMBO_GRACE`].
    pub combo: u32,
    /// Placements since the last clear.
    pub since_clear: u32,
    pub difficulty: Difficulty,
    pub game_over: bool,
    rng: Rng,
}

const PERMS: [[usize; 3]; 6] = [
    [0, 1, 2],
    [0, 2, 1],
    [1, 0, 2],
    [1, 2, 0],
    [2, 0, 1],
    [2, 1, 0],
];

/// Whether the three shapes can all be placed on `grid`, in some order, with the clears
/// in between. `None` when the search budget ran out before an answer.
pub fn solvable(grid: &Grid, shapes: [usize; 3]) -> Option<bool> {
    let mut budget = SEARCH_BUDGET;
    for perm in PERMS {
        let order = [shapes[perm[0]], shapes[perm[1]], shapes[perm[2]]];
        match search(grid, &order, &mut budget) {
            Some(false) => {}
            answer => return answer,
        }
    }
    Some(false)
}

fn search(grid: &Grid, order: &[usize], budget: &mut u32) -> Option<bool> {
    let Some((&first, rest)) = order.split_first() else {
        return Some(true);
    };
    let shape = &SHAPES[first];
    if rest.is_empty() {
        return Some(fits_anywhere(grid, shape));
    }
    for r in 0..=N - shape.height() {
        for c in 0..=N - shape.width() {
            if !fits(grid, shape, r as i32, c as i32) {
                continue;
            }
            if *budget == 0 {
                return None;
            }
            *budget -= 1;
            let mut g = *grid;
            stamp(&mut g, shape, r, c, 0);
            let (rows, cols) = full_lines(&g);
            clear_lines(&mut g, &rows, &cols);
            match search(&g, rest, budget) {
                Some(false) => {}
                answer => return answer,
            }
        }
    }
    Some(false)
}

impl Model {
    /// A fresh game with its first tray dealt.
    pub fn new(seed: u64, difficulty: Difficulty) -> Model {
        let mut m = Model {
            grid: [None; CELLS],
            tray: [None; TRAY],
            score: 0,
            best: 0,
            combo: 0,
            since_clear: 0,
            difficulty,
            game_over: false,
            rng: Rng(seed | 1),
        };
        m.refill();
        m
    }

    /// Start over at `difficulty`, reseeding the generator. The best score stays.
    pub fn new_game(&mut self, difficulty: Difficulty, seed: u64) {
        let best = self.best;
        *self = Model::new(seed, difficulty);
        self.best = best;
    }

    pub fn can_place(&self, slot: usize, row: i32, col: i32) -> bool {
        self.tray
            .get(slot)
            .copied()
            .flatten()
            .is_some_and(|p| fits(&self.grid, p.shape(), row, col))
    }

    /// Whether the piece in `slot` fits anywhere (the tray dims the ones that do not).
    pub fn slot_fits(&self, slot: usize) -> bool {
        self.tray
            .get(slot)
            .copied()
            .flatten()
            .is_some_and(|p| fits_anywhere(&self.grid, p.shape()))
    }

    fn any_fits(&self) -> bool {
        (0..TRAY).any(|s| self.slot_fits(s))
    }

    /// The rows and columns placing `slot`'s piece at `(row, col)` would complete (the
    /// preview lights them up before the drop).
    pub fn lines_if_placed(&self, slot: usize, row: i32, col: i32) -> (Vec<usize>, Vec<usize>) {
        let Some(piece) = self.tray.get(slot).copied().flatten() else {
            return (Vec::new(), Vec::new());
        };
        if !fits(&self.grid, piece.shape(), row, col) {
            return (Vec::new(), Vec::new());
        }
        let mut g = self.grid;
        stamp(
            &mut g,
            piece.shape(),
            row as usize,
            col as usize,
            piece.color,
        );
        full_lines(&g)
    }

    /// Where the keyboard first puts `slot`'s piece: the fitting position whose center is
    /// nearest the middle of the board, the first in reading order on a tie.
    pub fn nearest_fit(&self, slot: usize) -> Option<(i32, i32)> {
        let piece = self.tray.get(slot).copied().flatten()?;
        let shape = piece.shape();
        let (h, w) = (shape.height(), shape.width());
        let mid = (N as f64 - 1.0) / 2.0;
        let mut best: Option<((i32, i32), f64)> = None;
        for r in 0..=N - h {
            for c in 0..=N - w {
                if !fits(&self.grid, shape, r as i32, c as i32) {
                    continue;
                }
                let dr = r as f64 + (h as f64 - 1.0) / 2.0 - mid;
                let dc = c as f64 + (w as f64 - 1.0) / 2.0 - mid;
                let d = dr * dr + dc * dc;
                if best.is_none_or(|(_, bd)| d < bd - 1e-9) {
                    best = Some(((r as i32, c as i32), d));
                }
            }
        }
        best.map(|(p, _)| p)
    }

    /// Place `slot`'s piece with its top-left cell at `(row, col)`: fill the cells, clear
    /// every full row and column at once, score the move, deal a new tray when this was the
    /// last piece, and decide whether the game is over. `None` (and no change) when the game
    /// has ended, the slot is empty, or the piece does not fit there.
    pub fn place(&mut self, slot: usize, row: i32, col: i32) -> Option<Placement> {
        if self.game_over {
            return None;
        }
        let piece = self.tray.get(slot).copied().flatten()?;
        let shape = piece.shape();
        if !fits(&self.grid, shape, row, col) {
            return None;
        }
        let (r0, c0) = (row as usize, col as usize);
        stamp(&mut self.grid, shape, r0, c0, piece.color);
        let cells = shape
            .cells
            .iter()
            .map(|&(r, c)| idx(r0 + r as usize, c0 + c as usize))
            .collect();
        self.tray[slot] = None;

        let (rows, cols) = full_lines(&self.grid);
        let cleared = clear_lines(&mut self.grid, &rows, &cols);
        let lines = rows.len() + cols.len();
        if lines > 0 {
            self.combo += 1;
            self.since_clear = 0;
        } else {
            self.since_clear += 1;
            if self.since_clear >= COMBO_GRACE {
                self.combo = 0;
            }
        }
        let perfect = lines > 0 && self.grid.iter().all(Option::is_none);
        let combo = if lines > 0 { self.combo } else { 0 };
        let gain = move_score(shape.size(), lines, combo, perfect);
        self.score += gain;
        self.best = self.best.max(self.score);

        let refilled = self.tray.iter().all(Option::is_none);
        if refilled {
            self.refill();
        }
        self.game_over = !self.any_fits();
        Some(Placement {
            cells,
            rows,
            cols,
            cleared,
            gain,
            combo: self.combo,
            perfect,
            refilled,
            game_over: self.game_over,
        })
    }

    /// Three random shapes in three different colors.
    fn random_set(&mut self) -> [Piece; TRAY] {
        let mut colors: Vec<u8> = (0..COLORS).collect();
        let mut set = [Piece { shape: 0, color: 0 }; TRAY];
        for p in &mut set {
            let color = colors.remove(self.rng.below(colors.len()));
            *p = Piece {
                shape: self.rng.below(SHAPES.len()),
                color,
            };
        }
        set
    }

    /// Easy's guarantee: build a set one piece at a time, each drawn from the shapes that
    /// still fit after the previous ones are placed (first fit, clears applied), so the set
    /// can always be placed in dealing order. `None` only when nothing fits at all.
    fn constructed_set(&mut self) -> Option<[Piece; TRAY]> {
        let mut grid = self.grid;
        let mut set = self.random_set();
        for p in &mut set {
            let fitting: Vec<usize> = (0..SHAPES.len())
                .filter(|&s| fits_anywhere(&grid, &SHAPES[s]))
                .collect();
            if fitting.is_empty() {
                return None;
            }
            let shape = fitting[self.rng.below(fitting.len())];
            p.shape = shape;
            let s = &SHAPES[shape];
            'place: for r in 0..=N - s.height() {
                for c in 0..=N - s.width() {
                    if fits(&grid, s, r as i32, c as i32) {
                        stamp(&mut grid, s, r, c, p.color);
                        let (rows, cols) = full_lines(&grid);
                        clear_lines(&mut grid, &rows, &cols);
                        break 'place;
                    }
                }
            }
        }
        Some(set)
    }

    /// Deal a new tray under the difficulty's rules.
    fn refill(&mut self) {
        for _ in 0..self.difficulty.attempts() {
            let set = self.random_set();
            let shapes = [set[0].shape, set[1].shape, set[2].shape];
            if solvable(&self.grid, shapes) != Some(false) {
                self.tray = set.map(Some);
                return;
            }
        }
        if self.difficulty == Difficulty::Easy
            && let Some(set) = self.constructed_set()
        {
            self.tray = set.map(Some);
            return;
        }
        self.tray = self.random_set().map(Some);
    }

    pub fn save_state(&self) -> SaveState {
        SaveState {
            grid: self
                .grid
                .iter()
                .map(|c| c.map_or(-1, |v| v as i8))
                .collect(),
            tray: self
                .tray
                .iter()
                .map(|p| p.map(|p| (p.shape().id.to_string(), p.color)))
                .collect(),
            score: self.score,
            best: self.best,
            combo: self.combo,
            since_clear: self.since_clear,
            difficulty: self.difficulty,
            game_over: self.game_over,
        }
    }

    /// Adopt a saved game. A save that does not describe a legal position (wrong size, an
    /// unknown shape, a color out of range) is rejected and leaves the model untouched.
    pub fn apply_save(&mut self, s: SaveState) -> bool {
        if s.grid.len() != CELLS || s.tray.len() != TRAY {
            return false;
        }
        let mut grid = [None; CELLS];
        for (cell, &v) in grid.iter_mut().zip(&s.grid) {
            *cell = match v {
                -1 => None,
                v if v >= 0 && (v as u8) < COLORS => Some(v as u8),
                _ => return false,
            };
        }
        let mut tray = [None; TRAY];
        for (slot, saved) in tray.iter_mut().zip(&s.tray) {
            if let Some((id, color)) = saved {
                let Some(shape) = SHAPES.iter().position(|sh| sh.id == id) else {
                    return false;
                };
                if *color >= COLORS {
                    return false;
                }
                *slot = Some(Piece {
                    shape,
                    color: *color,
                });
            }
        }
        self.grid = grid;
        self.tray = tray;
        self.score = s.score.max(0);
        self.best = s.best.max(self.score);
        self.combo = s.combo;
        self.since_clear = s.since_clear;
        self.difficulty = s.difficulty;
        // Recomputed rather than trusted, and an empty tray (never saved by this code) deals.
        if self.tray.iter().all(Option::is_none) {
            self.refill();
        }
        self.game_over = !self.any_fits();
        true
    }
}

/// The durable game (gamekit save/restore). Effects are session-only.
#[derive(Serialize, Deserialize)]
pub struct SaveState {
    /// Row-major colors, -1 where empty.
    pub grid: Vec<i8>,
    /// Each slot's shape id and color, `None` once placed.
    pub tray: Vec<Option<(String, u8)>>,
    pub score: i64,
    pub best: i64,
    pub combo: u32,
    pub since_clear: u32,
    pub difficulty: Difficulty,
    pub game_over: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shape(id: &str) -> usize {
        SHAPES.iter().position(|s| s.id == id).expect("known shape")
    }

    /// A model on an empty board with the given tray (all red).
    fn with_tray(ids: [&str; 3]) -> Model {
        let mut m = Model::new(7, Difficulty::Normal);
        m.grid = [None; CELLS];
        m.tray = ids.map(|id| {
            Some(Piece {
                shape: shape(id),
                color: 0,
            })
        });
        m
    }

    fn fill(m: &mut Model, cells: impl IntoIterator<Item = usize>) {
        for i in cells {
            m.grid[i] = Some(3);
        }
    }

    #[test]
    fn shapes_are_unique_normalized_and_named() {
        for (i, s) in SHAPES.iter().enumerate() {
            assert!(s.cells.iter().any(|c| c.0 == 0), "{} touches row 0", s.id);
            assert!(s.cells.iter().any(|c| c.1 == 0), "{} touches col 0", s.id);
            for t in &SHAPES[i + 1..] {
                assert_ne!(s.id, t.id);
                let mut a = s.cells.to_vec();
                let mut b = t.cells.to_vec();
                a.sort_unstable();
                b.sort_unstable();
                assert_ne!(a, b, "{} and {} are the same shape", s.id, t.id);
            }
        }
    }

    #[test]
    fn placement_fills_cells_and_scores_ten_a_cell() {
        let mut m = with_tray(["L_bl", "dot", "dot"]);
        let p = m.place(0, 2, 3).expect("fits");
        assert_eq!(p.cells, vec![idx(2, 3), idx(3, 3), idx(3, 4)]);
        assert!(p.cells.iter().all(|&i| m.grid[i] == Some(0)));
        assert_eq!(p.gain, 30);
        assert_eq!(m.score, 30);
        assert_eq!(m.tray[0], None, "the slot empties");
        assert!(!p.refilled, "two pieces are still in the tray");
    }

    #[test]
    fn overlap_and_out_of_bounds_are_refused_without_change() {
        let mut m = with_tray(["h3", "dot", "dot"]);
        m.grid[idx(0, 2)] = Some(1);
        let before = m.grid;
        assert!(m.place(0, 0, 0).is_none(), "overlaps a filled cell");
        assert!(m.place(0, 0, 6).is_none(), "runs off the right edge");
        assert!(m.place(0, -1, 0).is_none(), "above the board");
        assert_eq!(m.grid, before);
        assert_eq!(m.score, 0);
        assert!(m.tray[0].is_some());
    }

    #[test]
    fn a_full_row_and_a_full_column_clear_together_and_share_their_crossing() {
        let mut m = with_tray(["dot", "dot", "dot"]);
        // Row 5 and column 2 complete except for their crossing cell (5, 2).
        fill(&mut m, (0..N).filter(|&c| c != 2).map(|c| idx(5, c)));
        fill(&mut m, (0..N).filter(|&r| r != 5).map(|r| idx(r, 2)));
        m.grid[idx(0, 0)] = Some(4); // a bystander that must survive
        let p = m.place(0, 5, 2).expect("fits");
        assert_eq!(p.rows, vec![5]);
        assert_eq!(p.cols, vec![2]);
        assert_eq!(p.cleared.len(), 15, "8 + 8 cells, the crossing once");
        assert!((0..N).all(|c| m.grid[idx(5, c)].is_none()));
        assert!((0..N).all(|r| m.grid[idx(r, 2)].is_none()));
        assert_eq!(m.grid[idx(0, 0)], Some(4));
        assert_eq!(
            p.gain,
            10 + 400,
            "one cell, two lines squared, first combo ×1"
        );
        assert!(!p.perfect);
    }

    #[test]
    fn combos_multiply_and_survive_two_clearless_placements() {
        let mut m = with_tray(["dot", "dot", "dot"]);
        let mut gains = Vec::new();
        // Four clears in a row, each completing row 0 with one dot.
        for round in 0..4 {
            m.tray = [Some(Piece {
                shape: shape("dot"),
                color: 0,
            }); 3];
            fill(&mut m, (1..N).map(|c| idx(0, c)));
            m.grid[idx(7, round)] = Some(2); // keeps the board from emptying
            let p = m.place(0, 0, 0).expect("fits");
            gains.push((p.gain, p.combo));
        }
        assert_eq!(gains, vec![(110, 1), (165, 2), (220, 3), (275, 4)]);
        // Two clearless placements keep the streak; the third ends it.
        m.tray = [Some(Piece {
            shape: shape("dot"),
            color: 0,
        }); 3];
        m.place(0, 3, 3).unwrap();
        m.place(1, 3, 5).unwrap();
        assert_eq!(m.combo, 4, "still alive after two misses");
        m.place(2, 5, 5).unwrap();
        assert_eq!(m.combo, 0, "the third miss breaks it");
    }

    #[test]
    fn emptying_the_board_pays_the_perfect_bonus() {
        let mut m = with_tray(["h2", "dot", "dot"]);
        fill(&mut m, (0..6).map(|c| idx(4, c)));
        let p = m.place(0, 4, 6).expect("fits");
        assert!(p.perfect);
        assert_eq!(p.gain, 20 + 100 + PERFECT_BONUS);
        assert_eq!(p.tier(), 6);
    }

    #[test]
    fn a_new_tray_is_dealt_only_after_all_three_are_placed() {
        let mut m = with_tray(["dot", "dot", "dot"]);
        assert!(!m.place(0, 0, 0).unwrap().refilled);
        assert!(!m.place(1, 0, 2).unwrap().refilled);
        let p = m.place(2, 0, 4).unwrap();
        assert!(p.refilled);
        assert!(m.tray.iter().all(Option::is_some));
    }

    #[test]
    fn the_game_ends_when_no_tray_piece_fits() {
        let mut m = with_tray(["dot", "sq3", "h5"]);
        // A checkerboard of holes: every row and column keeps four, so one dot completes no
        // line, and no two holes touch, so only a single block fits anywhere.
        fill(&mut m, (0..CELLS).filter(|i| (i / N + i % N) % 2 == 1));
        let p = m.place(0, 0, 0).expect("the dot fits");
        assert_eq!(p.lines(), 0);
        assert!(
            p.game_over,
            "neither the 3×3 nor the 1×5 fits the last hole"
        );
        assert!(m.game_over);
        assert!(m.place(1, 0, 0).is_none(), "no moves after the end");
    }

    #[test]
    fn solvability_sees_orders_greedy_first_fit_would_miss() {
        // Row 7 is full except its last three cells; an h3 there clears the row, which is
        // the only way to make room for the sq3 below the wall.
        let mut g: Grid = [Some(1); CELLS];
        for c in 5..N {
            g[idx(7, c)] = None;
        }
        for r in 5..7 {
            for c in 0..3 {
                g[idx(r, c)] = None;
            }
        }
        // sq3 needs rows 5-7 × cols 0-2 free: only after row 7 clears.
        assert_eq!(
            solvable(&g, [shape("sq3"), shape("h3"), shape("dot")]),
            Some(true)
        );
        assert_eq!(
            solvable(&g, [shape("sq3"), shape("sq3"), shape("sq3")]),
            Some(false)
        );
    }

    #[test]
    fn easy_always_deals_a_tray_that_can_be_placed() {
        let mut m = Model::new(11, Difficulty::Easy);
        let mut rng = Rng(99);
        for _ in 0..60 {
            // A crowded random board that still has room for a single cell.
            let mut g: Grid = [None; CELLS];
            for cell in g.iter_mut() {
                if rng.below(100) < 62 {
                    *cell = Some(2);
                }
            }
            g[idx(rng.below(N), rng.below(N))] = None;
            m.grid = g;
            m.refill();
            let shapes = m.tray.map(|p| p.expect("dealt").shape);
            assert_ne!(
                solvable(&m.grid, shapes),
                Some(false),
                "Easy dealt a dead tray"
            );
        }
    }

    #[test]
    fn nearest_fit_prefers_the_middle() {
        let m = with_tray(["sq2", "dot", "dot"]);
        assert_eq!(m.nearest_fit(0), Some((3, 3)));
    }

    #[test]
    fn lines_if_placed_previews_the_clear_without_changing_the_board() {
        let mut m = with_tray(["h2", "dot", "dot"]);
        fill(&mut m, (0..6).map(|c| idx(2, c)));
        let before = m.grid;
        assert_eq!(m.lines_if_placed(0, 2, 6), (vec![2], vec![]));
        assert_eq!(m.lines_if_placed(0, 3, 6), (vec![], vec![]));
        assert_eq!(m.grid, before);
    }

    #[test]
    fn save_restore_round_trips_and_bad_saves_are_refused() {
        let mut m = with_tray(["T_up", "v3", "dot"]);
        m.place(1, 0, 0).unwrap();
        m.score = 1234;
        m.best = 5000;
        let saved = m.save_state();
        let mut r = Model::new(3, Difficulty::Hard);
        assert!(r.apply_save(saved));
        assert_eq!(r.grid, m.grid);
        assert_eq!(r.tray, m.tray);
        assert_eq!(
            (r.score, r.best, r.difficulty),
            (1234, 5000, Difficulty::Normal)
        );

        let mut bad = m.save_state();
        bad.tray[0] = Some(("hexagon".into(), 0));
        let mut r = Model::new(3, Difficulty::Hard);
        let before = r.grid;
        assert!(!r.apply_save(bad));
        assert_eq!(r.grid, before, "a refused save changes nothing");
        let mut short = m.save_state();
        short.grid.pop();
        assert!(!Model::new(3, Difficulty::Hard).apply_save(short));
    }

    #[test]
    fn move_score_matches_the_published_table() {
        assert_eq!(move_score(4, 0, 0, false), 40);
        assert_eq!(move_score(3, 1, 1, false), 130);
        assert_eq!(move_score(3, 2, 2, false), (30 + 400) * 3 / 2);
        assert_eq!(move_score(5, 3, 9, false), (50 + 900) * 4);
        assert_eq!(move_score(1, 1, 1, true), 110 + PERFECT_BONUS);
    }
}
