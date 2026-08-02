//! 2048 — a sliding-tile number puzzle on an immediate-mode canvas. Slides/merges/spawns tween on
//! Day's frame clock (§8.4). A composite Day piece: pure composition over `day_pieces`. Swipe to
//! move; combine equal tiles to reach 2048.

use std::cell::RefCell;
use std::rc::Rc;

use day_fluent::tr;
use day_pieces::prelude::*;
use serde::{Deserialize, Serialize};

/// The prefs key this game's state persists under (gamekit; bump on schema change).
const SAVE_KEY: &str = "twentyfortyeight.v1";

const N: usize = 4;
const GAP: f64 = 8.0;
const SLIDE_DUR: f64 = 0.11;
const POP_DUR: f64 = 0.09;
/// Drag distance (points) for a full provisional slide (progress 1.0).
const SLIDE_SPAN: f64 = 96.0;
/// Release at or past this progress commits the move; under it the tiles slide back.
const COMMIT_FRACTION: f64 = 0.4;

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

/// A tile in flight during the slide phase.
#[derive(Clone, Copy)]
struct Slide {
    value: u32,
    from: (usize, usize),
    to: (usize, usize),
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Phase {
    Idle,
    Slide,
    Pop,
}

struct Anim {
    phase: Phase,
    t: f64,
    slides: Vec<Slide>,
    next: [[u32; N]; N],
    pops: Vec<(usize, usize)>, // merged results + the spawned tile
    spawn: Option<(usize, usize)>,
    /// Whether this slide lands the move (score + spawn) or just returns the tiles to where
    /// they were (a provisional drag released under the commit threshold).
    commit: bool,
}

/// A move computed for a drag in progress: everything needed to preview it (tiles tracking
/// the finger toward `slides[..].to`), then commit or abandon it on release.
struct Pending {
    dir: u8,
    slides: Vec<Slide>,
    next: [[u32; N]; N],
    pops: Vec<(usize, usize)>,
    gained: i64,
}

struct Game {
    field: Size,
    grid: [[u32; N]; N],
    score: i64,
    best: i64,
    won: bool,
    game_over: bool,
    anim: Anim,
    rng: Rng,
    /// The provisional move under the current drag, and its finger-tracked progress (0..1).
    /// `None` also when the drag's direction has no legal move.
    pending: Option<Pending>,
    pending_t: f64,
}

/// The durable subset of [`Game`] (gamekit save/restore): the board and scoring. Tweens are
/// session-only; a save taken mid-slide stores the settled (post-move) grid.
#[derive(Serialize, Deserialize)]
struct SaveState {
    grid: [[u32; N]; N],
    score: i64,
    best: i64,
    won: bool,
}

fn tile_color(v: u32) -> Color {
    match v {
        2 => Color::hex(0xEE_E4_DA),
        4 => Color::hex(0xED_E0_C8),
        8 => Color::hex(0xF2_B1_79),
        16 => Color::hex(0xF5_95_63),
        32 => Color::hex(0xF6_7C_5F),
        64 => Color::hex(0xF6_5E_3B),
        128 => Color::hex(0xED_CF_72),
        256 => Color::hex(0xED_CC_61),
        512 => Color::hex(0xED_C8_50),
        1024 => Color::hex(0xED_C5_3F),
        2048 => Color::hex(0xED_C2_2E),
        _ => Color::hex(0x3C3A32),
    }
}
fn tile_text_color(v: u32) -> Color {
    if v <= 4 {
        Color::hex(0x77_6E_65)
    } else {
        Color::hex(0xF9_F6_F2)
    }
}

fn ease_out(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    1.0 - (1.0 - t) * (1.0 - t)
}

/// The `t` at which [`ease_out`] reaches `v` — so an animation taking over from a
/// finger-tracked (linear) preview starts exactly where the tiles are, no jump.
fn ease_out_inv(v: f64) -> f64 {
    1.0 - (1.0 - v.clamp(0.0, 1.0)).sqrt()
}

/// One value tile in a `cell`-sized slot at `(x, y)` — the rendering (colors, corner radius,
/// digit sizing) shared by the gameplay renderer and the home-tile preview.
fn draw_tile(d: &mut Draw, x: f64, y: f64, cell: f64, value: u32, scale: f64) {
    let s = cell * scale;
    let off = (cell - s) / 2.0;
    d.fill(
        Shape::RoundedRect(Rect::new(x + off, y + off, s, s), 6.0),
        tile_color(value),
    );
    let digits = value.to_string();
    let fsize = match digits.len() {
        1 => cell * 0.44,
        2 => cell * 0.38,
        3 => cell * 0.30,
        _ => cell * 0.24,
    };
    d.text(
        &digits,
        Point::new(x + cell / 2.0, y + cell / 2.0),
        TextStyle {
            size: fsize,
            color: tile_text_color(value),
            anchor: TextAnchor::Centered,
        },
    );
}

impl Game {
    fn new() -> Self {
        let seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0xD1B5_4A32_D192_ED03)
            | 1;
        let mut g = Game {
            field: Size::new(0.0, 0.0),
            grid: [[0; N]; N],
            score: 0,
            best: 0,
            won: false,
            game_over: false,
            anim: Anim {
                phase: Phase::Idle,
                t: 0.0,
                slides: Vec::new(),
                next: [[0; N]; N],
                pops: Vec::new(),
                spawn: None,
                commit: true,
            },
            rng: Rng(seed),
            pending: None,
            pending_t: 0.0,
        };
        g.spawn();
        g.spawn();
        g
    }

    fn spawn(&mut self) -> Option<(usize, usize)> {
        let empties: Vec<(usize, usize)> = (0..N)
            .flat_map(|r| (0..N).map(move |c| (r, c)))
            .filter(|&(r, c)| self.grid[r][c] == 0)
            .collect();
        if empties.is_empty() {
            return None;
        }
        let (r, c) = empties[(self.rng.next() as usize) % empties.len()];
        self.grid[r][c] = if self.rng.next().is_multiple_of(10) {
            4
        } else {
            2
        };
        Some((r, c))
    }

    /// The cells of one line in travel order (index 0 = the wall we slide toward).
    fn line_coords(dir: u8, i: usize) -> [(usize, usize); N] {
        let mut out = [(0, 0); N];
        for (k, slot) in out.iter_mut().enumerate() {
            *slot = match dir {
                0 => (i, k),         // left: row i, cols 0..N
                1 => (i, N - 1 - k), // right
                2 => (k, i),         // up: col i, rows 0..N
                _ => (N - 1 - k, i), // down
            };
        }
        out
    }

    /// Work out what sliding toward `dir` would do — pure: nothing is applied. `None` when
    /// no tile can move that way.
    fn compute_move(&self, dir: u8) -> Option<Pending> {
        let mut next = [[0u32; N]; N];
        let mut slides: Vec<Slide> = Vec::new();
        let mut pops: Vec<(usize, usize)> = Vec::new();
        let mut gained = 0i64;
        let mut moved = false;

        for i in 0..N {
            let coords = Self::line_coords(dir, i);
            let vals: Vec<(u32, (usize, usize))> = coords
                .iter()
                .map(|&(r, c)| (self.grid[r][c], (r, c)))
                .filter(|&(v, _)| v != 0)
                .collect();
            let mut slot = 0usize;
            let mut k = 0usize;
            while k < vals.len() {
                let (v, from) = vals[k];
                let to = coords[slot];
                if k + 1 < vals.len() && vals[k + 1].0 == v {
                    // merge two tiles into `to`
                    next[to.0][to.1] = v * 2;
                    gained += (v * 2) as i64;
                    pops.push(to);
                    slides.push(Slide { value: v, from, to });
                    slides.push(Slide {
                        value: v,
                        from: vals[k + 1].1,
                        to,
                    });
                    moved = true; // a merge always changes the board
                    k += 2;
                } else {
                    next[to.0][to.1] = v;
                    slides.push(Slide { value: v, from, to });
                    if from != to {
                        moved = true;
                    }
                    k += 1;
                }
                slot += 1;
            }
        }

        moved.then_some(Pending {
            dir,
            slides,
            next,
            pops,
            gained,
        })
    }

    /// Track a drag in progress: (re)compute the provisional move for `dir` and set its
    /// finger progress. The tiles render at `t` of the way to their post-move positions;
    /// nothing is applied until [`Game::release_preview`].
    fn preview(&mut self, dir: u8, t: f64) {
        if self.anim.phase != Phase::Idle || self.game_over {
            return;
        }
        if self.pending.as_ref().map(|p| p.dir) != Some(dir) {
            self.pending = self.compute_move(dir);
        }
        self.pending_t = t.clamp(0.0, 1.0);
    }

    fn clear_preview(&mut self) {
        self.pending = None;
        self.pending_t = 0.0;
    }

    /// Finger lifted: past the threshold the previewed move lands (score, merge pops, and
    /// the new tile); under it the tiles animate back where they came from and nothing
    /// happened.
    fn release_preview(&mut self) {
        let Some(p) = self.pending.take() else {
            return;
        };
        let t = self.pending_t;
        self.pending_t = 0.0;
        if t >= COMMIT_FRACTION {
            self.commit_pending(p, t);
        } else if t > 0.0 {
            // Slide back: the same tiles, reversed, picking up exactly where the finger
            // left them. Completion re-applies the unchanged grid and spawns nothing.
            let slides = p
                .slides
                .iter()
                .map(|s| Slide {
                    value: s.value,
                    from: s.to,
                    to: s.from,
                })
                .collect();
            self.anim = Anim {
                phase: Phase::Slide,
                t: ease_out_inv(1.0 - t),
                slides,
                next: self.grid,
                pops: Vec::new(),
                spawn: None,
                commit: false,
            };
        }
    }

    /// Land `p`: score it and run the slide animation from finger progress `from_t`.
    fn commit_pending(&mut self, p: Pending, from_t: f64) {
        self.score += p.gained;
        if self.score > self.best {
            self.best = self.score;
        }
        self.anim = Anim {
            phase: Phase::Slide,
            t: ease_out_inv(from_t),
            slides: p.slides,
            next: p.next,
            pops: p.pops,
            spawn: None,
            commit: true,
        };
    }

    fn any_moves_left(&self) -> bool {
        for r in 0..N {
            for c in 0..N {
                if self.grid[r][c] == 0 {
                    return true;
                }
                if c + 1 < N && self.grid[r][c] == self.grid[r][c + 1] {
                    return true;
                }
                if r + 1 < N && self.grid[r][c] == self.grid[r + 1][c] {
                    return true;
                }
            }
        }
        false
    }

    fn restart(&mut self) {
        self.grid = [[0; N]; N];
        self.score = 0;
        self.won = false;
        self.game_over = false;
        self.anim.phase = Phase::Idle;
        self.clear_preview();
        self.spawn();
        self.spawn();
    }

    /// Snapshot the durable state (gamekit). Mid-slide the settled post-move grid is the
    /// truth; the spawn that would follow is granted on restore. A finished game keeps only
    /// the best score.
    fn save_state(&self) -> SaveState {
        if self.game_over {
            let mut g = Game::new();
            g.best = self.best;
            return g.save_state();
        }
        let grid = if self.anim.phase == Phase::Slide {
            self.anim.next
        } else {
            self.grid
        };
        SaveState {
            grid,
            score: self.score,
            best: self.best,
            won: self.won,
        }
    }

    /// Rebuild from a snapshot: board + scores back, tweens idle.
    fn apply_save(&mut self, s: SaveState) {
        self.grid = s.grid;
        self.score = s.score;
        self.best = s.best.max(s.score);
        self.won = s.won;
        self.anim.phase = Phase::Idle;
        self.game_over = false;
        if self.grid.iter().flatten().all(|&v| v == 0) {
            self.spawn();
            self.spawn();
        } else if !self.any_moves_left() {
            // A save that somehow captured a dead board starts fresh (best kept).
            let best = self.best;
            self.restart();
            self.best = best;
        }
    }

    fn step(&mut self, dt: f64) {
        match self.anim.phase {
            Phase::Idle => {}
            Phase::Slide => {
                self.anim.t += dt / SLIDE_DUR;
                if self.anim.t >= 1.0 {
                    if self.anim.commit {
                        // Commit the merged grid and spawn a new tile.
                        self.grid = self.anim.next;
                        let sp = self.spawn();
                        self.anim.spawn = sp;
                        if let Some(s) = sp {
                            self.anim.pops.push(s);
                        }
                        if !self.won && self.grid.iter().flatten().any(|&v| v >= 2048) {
                            self.won = true;
                        }
                        self.anim.phase = Phase::Pop;
                        self.anim.t = 0.0;
                    } else {
                        // A cancelled preview slid back — the board never changed.
                        self.anim.phase = Phase::Idle;
                        self.anim.pops.clear();
                    }
                }
            }
            Phase::Pop => {
                self.anim.t += dt / POP_DUR;
                if self.anim.t >= 1.0 {
                    self.anim.phase = Phase::Idle;
                    self.anim.pops.clear();
                    if !self.any_moves_left() {
                        self.game_over = true;
                    }
                }
            }
        }
    }

    // --- geometry ---
    fn board(&self) -> (f64, f64, f64, f64) {
        // returns (origin_x, origin_y, board_size, cell_size)
        let w = self.field.width;
        let h = self.field.height;
        let size = (w - 32.0).min(h - 150.0).max(80.0);
        let cell = (size - (N as f64 + 1.0) * GAP) / N as f64;
        let ox = (w - size) / 2.0;
        let oy = 120.0;
        (ox, oy, size, cell)
    }
    fn cell_xy(&self, r: usize, c: usize) -> (f64, f64) {
        let (ox, oy, _s, cell) = self.board();
        (
            ox + GAP + c as f64 * (cell + GAP),
            oy + GAP + r as f64 * (cell + GAP),
        )
    }

    fn draw(&self, d: &mut Draw, sz: Size) {
        d.fill(
            Shape::Rect(Rect::new(0.0, 0.0, sz.width, sz.height)),
            Color::hex(0xFA_F8_EF),
        );
        let (ox, oy, size, cell) = self.board();
        // Board + empty cells.
        d.fill(
            Shape::RoundedRect(Rect::new(ox, oy, size, size), 8.0),
            Color::hex(0xBB_AD_A0),
        );
        for r in 0..N {
            for c in 0..N {
                let (x, y) = self.cell_xy(r, c);
                d.fill(
                    Shape::RoundedRect(Rect::new(x, y, cell, cell), 6.0),
                    Color::hex(0xCD_C1_B4),
                );
            }
        }

        // Header. The leading gutter keeps the title clear of the cover's close button.
        d.text(
            &tr("tf_title").format(),
            Point::new(ox.max(52.0), 34.0),
            TextStyle {
                size: 40.0,
                color: Color::hex(0x77_6E_65),
                anchor: TextAnchor::Leading,
            },
        );
        let stat = TextStyle {
            size: 15.0,
            color: Color::hex(0x77_6E_65),
            anchor: TextAnchor::Leading,
        };
        d.text(
            &tr("tf_score").arg("n", self.score).format(),
            Point::new(ox, 74.0),
            stat,
        );
        d.text(
            &tr("tf_best").arg("n", self.best).format(),
            Point::new(ox + size - 120.0, 74.0),
            stat,
        );

        // Tiles.
        match self.anim.phase {
            Phase::Slide => {
                let e = ease_out(self.anim.t);
                for s in &self.anim.slides {
                    let (fx, fy) = self.cell_xy(s.from.0, s.from.1);
                    let (tx, ty) = self.cell_xy(s.to.0, s.to.1);
                    let x = fx + (tx - fx) * e;
                    let y = fy + (ty - fy) * e;
                    draw_tile(d, x, y, cell, s.value, 1.0);
                }
            }
            // A drag in progress: the provisional move, tiles tracking the finger LINEARLY
            // (no ease — they must follow a slide back to the start exactly).
            Phase::Idle if self.pending.is_some() => {
                if let Some(p) = &self.pending {
                    for s in &p.slides {
                        let (fx, fy) = self.cell_xy(s.from.0, s.from.1);
                        let (tx, ty) = self.cell_xy(s.to.0, s.to.1);
                        let x = fx + (tx - fx) * self.pending_t;
                        let y = fy + (ty - fy) * self.pending_t;
                        draw_tile(d, x, y, cell, s.value, 1.0);
                    }
                }
            }
            _ => {
                let pop = ease_out(self.anim.t);
                for r in 0..N {
                    for c in 0..N {
                        let v = self.grid[r][c];
                        if v == 0 {
                            continue;
                        }
                        let (x, y) = self.cell_xy(r, c);
                        let is_pop =
                            self.anim.phase == Phase::Pop && self.anim.pops.contains(&(r, c));
                        let scale = if is_pop {
                            if self.anim.spawn == Some((r, c)) {
                                pop // spawn: 0 → 1
                            } else {
                                1.0 + 0.18 * (1.0 - pop) // merge: 1.18 → 1
                            }
                        } else {
                            1.0
                        };
                        draw_tile(d, x, y, cell, v, scale);
                    }
                }
            }
        }

        if self.game_over {
            d.fill(
                Shape::RoundedRect(Rect::new(ox, oy, size, size), 8.0),
                Color::rgba(0.93, 0.89, 0.85, 0.72),
            );
            d.text(
                &tr("tf_game_over").format(),
                Point::new(ox + size / 2.0, oy + size / 2.0 - 12.0),
                TextStyle {
                    size: 30.0,
                    color: Color::hex(0x77_6E_65),
                    anchor: TextAnchor::Centered,
                },
            );
            d.text(
                &tr("tf_try_again").format(),
                Point::new(ox + size / 2.0, oy + size / 2.0 + 24.0),
                TextStyle {
                    size: 16.0,
                    color: Color::hex(0x77_6E_65),
                    anchor: TextAnchor::Centered,
                },
            );
        } else if self.won {
            d.text(
                &tr("tf_keep_going").format(),
                Point::new(ox + size / 2.0, oy + size + 28.0),
                TextStyle {
                    size: 16.0,
                    color: Color::hex(0xF6_5E_3B),
                    anchor: TextAnchor::Centered,
                },
            );
        }
    }
}

/// The home-grid tile preview: a mini board drawn with the SAME tile renderer and palette
/// as gameplay ([`draw_tile`], [`tile_color`]).
pub fn twentyfortyeight_preview() -> AnyPiece {
    canvas(|d, sz| {
        if sz.width < 4.0 || sz.height < 4.0 {
            return;
        }
        d.fill(
            Shape::Rect(Rect::new(0.0, 0.0, sz.width, sz.height)),
            Color::hex(0xFA_F8_EF),
        );
        let gap = sz.width * 0.05;
        let board = sz.width.min(sz.height) - gap * 2.0;
        let (ox, oy) = ((sz.width - board) / 2.0, (sz.height - board) / 2.0);
        d.fill(
            Shape::RoundedRect(Rect::new(ox, oy, board, board), 8.0),
            Color::hex(0xBB_AD_A0),
        );
        let cell = (board - (N as f64 + 1.0) * gap) / N as f64;
        let values: [[u32; N]; N] = [
            [2, 0, 4, 0],
            [0, 8, 0, 2],
            [16, 0, 64, 0],
            [0, 128, 4, 2048],
        ];
        for (r, row) in values.iter().enumerate() {
            for (c, &v) in row.iter().enumerate() {
                let x = ox + gap + c as f64 * (cell + gap);
                let y = oy + gap + r as f64 * (cell + gap);
                d.fill(
                    Shape::RoundedRect(Rect::new(x, y, cell, cell), 6.0),
                    Color::hex(0xCD_C1_B4),
                );
                if v > 0 {
                    draw_tile(d, x, y, cell, v, 1.0);
                }
            }
        }
    })
    .any()
}

/// The 2048 screen.
pub fn twentyfortyeight_page() -> AnyPiece {
    let game = Rc::new(RefCell::new(Game::new()));
    if let Some(s) = gamekit::restore::<SaveState>(SAVE_KEY) {
        game.borrow_mut().apply_save(s);
    }
    gamekit::autosave(SAVE_KEY, {
        let game = game.clone();
        move || game.borrow().save_state()
    });
    let repaint = Trigger::new();

    let cv = {
        let game = game.clone();
        canvas(move |d, sz| {
            repaint.track();
            game.borrow_mut().field = sz;
            game.borrow().draw(d, sz);
        })
    }
    .on_drag({
        let game = game.clone();
        move |dr| {
            // The slide is PROVISIONAL while the finger is down: tiles track the drag
            // toward their post-move spots, slide back if the finger returns, and the move
            // commits only on release past the threshold.
            let mut g = game.borrow_mut();
            match dr.phase {
                DragPhase::Began => g.clear_preview(),
                DragPhase::Ended => g.release_preview(),
                _ => {
                    let (tx, ty) = (dr.translation.x, dr.translation.y);
                    let mag = tx.abs().max(ty.abs());
                    if mag < 6.0 {
                        // Too small to pick an axis — whatever was previewed eases to 0.
                        g.pending_t = 0.0;
                    } else {
                        let dir = if tx.abs() > ty.abs() {
                            if tx < 0.0 { 0 } else { 1 }
                        } else if ty < 0.0 {
                            2
                        } else {
                            3
                        };
                        g.preview(dir, mag / SLIDE_SPAN);
                    }
                }
            }
            drop(g);
            repaint.notify();
        }
    })
    .on_tap({
        let game = game.clone();
        move || {
            let mut g = game.borrow_mut();
            if g.game_over {
                g.restart();
            }
            drop(g);
            repaint.notify();
        }
    })
    .id("tf-canvas")
    .grow();

    let clock = frame_clock({
        let game = game.clone();
        move |dt| {
            // Turn-based: only repaint while an animation is in flight (idle frames do no work).
            let mut g = game.borrow_mut();
            let before = g.anim.phase;
            g.step(dt.as_secs_f64());
            let after = g.anim.phase;
            drop(g);
            if before != Phase::Idle || after != Phase::Idle {
                repaint.notify();
            }
        }
    });

    zstack((cv, clock)).any()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn game_with(grid: [[u32; N]; N]) -> Game {
        let mut g = Game::new();
        g.grid = grid;
        g
    }

    fn settle(g: &mut Game) {
        for _ in 0..200 {
            if g.anim.phase == Phase::Idle {
                break;
            }
            g.step(0.02);
        }
        assert_eq!(g.anim.phase, Phase::Idle, "animation settled");
    }

    #[test]
    fn preview_is_provisional_and_cancel_changes_nothing() {
        let grid = [[2, 0, 0, 2], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]];
        let mut g = game_with(grid);
        // Drag left, part way — nothing is applied while previewing.
        g.preview(0, 0.3);
        assert!(g.pending.is_some());
        assert_eq!(g.grid, grid, "grid untouched during preview");
        assert_eq!(g.score, 0, "score untouched during preview");
        // Slide back toward the origin and release: the move is abandoned.
        g.preview(0, 0.05);
        g.release_preview();
        settle(&mut g);
        assert_eq!(g.grid, grid, "cancelled release leaves the board as it was");
        assert_eq!(g.score, 0);
    }

    #[test]
    fn preview_release_past_threshold_commits() {
        let grid = [[2, 0, 0, 2], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]];
        let mut g = game_with(grid);
        g.preview(0, 0.9);
        g.release_preview();
        settle(&mut g);
        assert_eq!(g.grid[0][0], 4, "the pair merged left");
        assert_eq!(g.score, 4, "the merge scored");
        let tiles: usize = g.grid.iter().flatten().filter(|&&v| v != 0).count();
        assert_eq!(tiles, 2, "a new tile spawned after the commit");
    }

    #[test]
    fn preview_recomputes_when_the_drag_changes_direction() {
        let grid = [[2, 0, 0, 2], [0, 0, 0, 0], [0, 0, 0, 0], [2, 0, 0, 0]];
        let mut g = game_with(grid);
        g.preview(0, 0.2);
        assert_eq!(g.pending.as_ref().map(|p| p.dir), Some(0));
        g.preview(3, 0.2);
        assert_eq!(g.pending.as_ref().map(|p| p.dir), Some(3));
        assert_eq!(g.grid, grid, "still nothing applied");
    }
}
