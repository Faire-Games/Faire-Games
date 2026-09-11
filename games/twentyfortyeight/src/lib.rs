//! 2048 — a sliding-tile number puzzle on an immediate-mode canvas. Slides/merges/spawns tween on
//! Day's frame clock (§8.4). A composite Day piece: pure composition over `day_pieces`. Swipe to
//! move; combine equal tiles to reach 2048.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use day_fluent::tr;
use day_pieces::prelude::*;
use gamekit::chrome::cues::{self, with};
use gamekit::chrome::{self, Cue, Feedback, Help, Sfx, sfx};
use serde::{Deserialize, Serialize};

/// The prefs keys this game persists under (gamekit; bump the game key on schema change).
const SAVE_KEY: &str = "twentyfortyeight.v1";
const RECORD_KEY: &str = "twentyfortyeight.best";
const SETTINGS_KEY: &str = "twentyfortyeight.settings";
/// The game's cover surface color (edge-to-edge behind the safe area).
pub const SURFACE: Color = Color::hex(0xFA_F8_EF);

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
    fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }
}

/// The three rule sets (Faire's): how often a 4 spawns, how many tiles spawn per move, and
/// whether undo is on the table.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, Serialize, Deserialize)]
enum Difficulty {
    Easy,
    #[default]
    Normal,
    Hard,
}

const DIFFICULTIES: [Difficulty; 3] = [Difficulty::Easy, Difficulty::Normal, Difficulty::Hard];
/// Undos a game grants where the difficulty allows them.
const UNDOS: i32 = 3;

impl Difficulty {
    fn four_chance(self) -> f64 {
        match self {
            Difficulty::Easy => 0.0,
            Difficulty::Normal => 0.1,
            Difficulty::Hard => 0.2,
        }
    }
    fn tiles_per_spawn(self) -> usize {
        match self {
            Difficulty::Hard => 2,
            _ => 1,
        }
    }
    fn undo_allowed(self) -> bool {
        matches!(self, Difficulty::Easy)
    }
    fn accent(self) -> Color {
        match self {
            Difficulty::Easy => Color::rgb(0.35, 0.75, 0.45),
            Difficulty::Normal => Color::rgb(0.30, 0.60, 0.95),
            Difficulty::Hard => Color::rgb(0.90, 0.35, 0.30),
        }
    }
    /// LITERAL `tr` keys, so `day lint` tracks their coverage.
    fn label(self) -> day_fluent::LocalizedText {
        match self {
            Difficulty::Easy => tr("tf_easy"),
            Difficulty::Normal => tr("tf_normal"),
            Difficulty::Hard => tr("tf_hard"),
        }
    }
    fn detail(self) -> day_fluent::LocalizedText {
        match self {
            Difficulty::Easy => tr("tf_detail_easy"),
            Difficulty::Normal => tr("tf_detail_normal"),
            Difficulty::Hard => tr("tf_detail_hard"),
        }
    }
    fn id(self) -> &'static str {
        match self {
            Difficulty::Easy => "tf-diff-easy",
            Difficulty::Normal => "tf-diff-normal",
            Difficulty::Hard => "tf-diff-hard",
        }
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

/// What a move did that the page reacts to (haptics, cards).
#[derive(Clone, Copy, PartialEq, Debug)]
enum Happening {
    /// A move landed; the largest tile it made (0 when nothing merged).
    Moved(u32),
    Won,
    GameOver,
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
    difficulty: Difficulty,
    /// The board and score before the last committed move (Easy only), and the undos left.
    undo: Option<([[u32; N]; N], i64)>,
    undos_left: i32,
    happenings: Vec<Happening>,
}

/// The durable subset of [`Game`] (gamekit save/restore): the board and scoring. Tweens are
/// session-only; a save taken mid-slide stores the settled (post-move) grid.
#[derive(Serialize, Deserialize)]
struct SaveState {
    grid: [[u32; N]; N],
    score: i64,
    best: i64,
    won: bool,
    // Newer than the board fields: a save from before difficulties reads as Normal.
    #[serde(default)]
    difficulty: Difficulty,
    #[serde(default)]
    undo: Option<([[u32; N]; N], i64)>,
    #[serde(default = "default_undos")]
    undos_left: i32,
}

fn default_undos() -> i32 {
    UNDOS
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
            anchor: TextAnchor::CENTERED,
            ..Default::default()
        },
    );
}

impl Game {
    fn new() -> Self {
        let seed = gamekit::seed();
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
            difficulty: Difficulty::Normal,
            undo: None,
            undos_left: UNDOS,
            happenings: Vec::new(),
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
        self.grid[r][c] = if self.rng.unit() < self.difficulty.four_chance() {
            4
        } else {
            2
        };
        Some((r, c))
    }

    /// Take back the last committed move (Easy grants three per game).
    fn undo(&mut self) -> bool {
        if !self.difficulty.undo_allowed() || self.undos_left <= 0 || self.anim.phase != Phase::Idle
        {
            return false;
        }
        let Some((grid, score)) = self.undo.take() else {
            return false;
        };
        self.clear_preview();
        self.grid = grid;
        self.score = score;
        self.undos_left -= 1;
        self.game_over = false;
        true
    }

    fn can_undo(&self) -> bool {
        self.difficulty.undo_allowed() && self.undos_left > 0 && self.undo.is_some()
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
        if self.difficulty.undo_allowed() && self.undos_left > 0 {
            self.undo = Some((self.grid, self.score));
        }
        let biggest = p.pops.iter().map(|&(r, c)| p.next[r][c]).max().unwrap_or(0);
        self.happenings.push(Happening::Moved(biggest));
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

    fn restart(&mut self, difficulty: Difficulty) {
        self.difficulty = difficulty;
        self.undo = None;
        self.undos_left = UNDOS;
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
            difficulty: self.difficulty,
            undo: self.undo,
            undos_left: self.undos_left,
        }
    }

    /// Rebuild from a snapshot: board + scores back, tweens idle.
    fn apply_save(&mut self, s: SaveState) {
        self.grid = s.grid;
        self.score = s.score;
        self.best = s.best.max(s.score);
        self.won = s.won;
        self.difficulty = s.difficulty;
        self.undo = s.undo;
        self.undos_left = s.undos_left.clamp(0, UNDOS);
        self.anim.phase = Phase::Idle;
        self.game_over = false;
        if self.grid.iter().flatten().all(|&v| v == 0) {
            self.spawn();
            self.spawn();
        } else if !self.any_moves_left() {
            // A save that somehow captured a dead board starts fresh (best kept).
            let best = self.best;
            self.restart(self.difficulty);
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
                        // Hard spawns two tiles a move; the first is the one that pops in
                        // from nothing, the rest join the pop.
                        for k in 0..self.difficulty.tiles_per_spawn() {
                            let sp = self.spawn();
                            if k == 0 {
                                self.anim.spawn = sp;
                            }
                            if let Some(s) = sp {
                                self.anim.pops.push(s);
                            }
                        }
                        if !self.won && self.grid.iter().flatten().any(|&v| v >= 2048) {
                            self.won = true;
                            self.happenings.push(Happening::Won);
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
                        self.happenings.push(Happening::GameOver);
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
        let oy = self.top() + 120.0;
        (ox, oy, size, cell)
    }
    /// How far the header and board sit below the top: half the height they leave free, so a
    /// tall screen centers them rather than stacking them at the top. The block is the 120-point
    /// header, the board, and the 30 points under it for "keep going".
    fn top(&self) -> f64 {
        let (w, h) = (self.field.width, self.field.height);
        let size = (w - 32.0).min(h - 150.0).max(80.0);
        ((h - 150.0 - size) / 2.0).max(0.0)
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

        // Header: the title over the score, difficulty and best, each narrowing to fit its third
        // of the board's width. The leading gutter keeps the title clear of the cover's close
        // button, and its width stays clear of the undo and pause buttons.
        let t = self.top();
        let ink = Color::hex(0x77_6E_65);
        let plain = TextStyle::default().font;
        let title = tr("tf_title").format();
        let tx = ox.max(52.0);
        d.text(
            &title,
            Point::new(tx, t + 12.0),
            TextStyle {
                size: chrome::fit_text(&title, 40.0, &plain, (ox + size - tx) * 0.6),
                color: ink,
                anchor: TextAnchor::LEADING,
                ..Default::default()
            },
        );
        let score = tr("tf_score").arg("n", self.score).format();
        let level = self.difficulty.label().format();
        let best = tr("tf_best").arg("n", self.best).format();
        let third = size / 3.0 - 8.0;
        let stat = TextStyle {
            size: [&score, &level, &best]
                .iter()
                .map(|s| chrome::fit_text(s, 15.0, &plain, third))
                .fold(15.0, f64::min),
            color: ink,
            anchor: TextAnchor::LEADING,
            ..Default::default()
        };
        d.text(&score, Point::new(ox, t + 78.0), stat.clone());
        d.text(
            &level,
            Point::new(ox + size / 2.0, t + 78.0),
            TextStyle {
                anchor: TextAnchor {
                    h: TextAlign::Center,
                    v: TextVAlign::Top,
                },
                ..stat.clone()
            },
        );
        d.text(
            &best,
            Point::new(ox + size, t + 78.0),
            TextStyle {
                anchor: TextAnchor::TRAILING,
                ..stat
            },
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
                    anchor: TextAnchor::CENTERED,
                    ..Default::default()
                },
            );
        } else if self.won {
            d.text(
                &tr("tf_keep_going").format(),
                Point::new(ox + size / 2.0, oy + size + 28.0),
                TextStyle {
                    size: 16.0,
                    color: Color::hex(0xF6_5E_3B),
                    anchor: TextAnchor::CENTERED,
                    ..Default::default()
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

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Overlay {
    None,
    Pause,
    Won,
    GameOver,
    Difficulty,
    Settings,
    Instructions,
}

// Sounds, each with the haptic it plays beside (gamekit::chrome::Cue). A slide ticks; a merge
// rings deeper and lands harder the bigger the tile it makes.
static SLIDE: Cue = with("sounds/2048/slide.wav", cues::LIGHT_BEAT);
static MERGE_S: Cue = with("sounds/shared/pluck.wav", cues::MEDIUM_BEAT);
static MERGE_M: Cue = with("sounds/2048/merge_m.wav", cues::HEAVY_BEAT);
static MERGE_L: Cue = with("sounds/2048/merge_l.wav", chrome::THUD);
static UNDO: Cue = with("sounds/2048/undo.wav", chrome::LETDOWN);
static WON: Cue = with("sounds/2048/won.wav", chrome::BIG_CELEBRATE);

/// Every clip this game plays besides the shared ones (gamekit preloads both).
pub const SOUNDS: &[Sfx] = &[
    sfx("sounds/2048/slide.wav"),
    sfx("sounds/2048/merge_m.wav"),
    sfx("sounds/2048/merge_l.wav"),
    sfx("sounds/2048/undo.wav"),
    sfx("sounds/2048/won.wav"),
];

struct Ui {
    game: Rc<RefCell<Game>>,
    repaint: Trigger,
    overlay: Signal<Overlay>,
    /// Where the difficulty picker's Cancel returns to.
    return_to: Cell<Overlay>,
    sounds: Signal<bool>,
    vibrations: Signal<bool>,
}

impl Ui {
    fn feedback(&self) -> Feedback {
        Feedback {
            sounds: self.sounds.get_untracked(),
            vibrations: self.vibrations.get_untracked(),
        }
    }
    fn cue(&self, c: &Cue) {
        chrome::cue(self.feedback(), c);
    }
    fn show(&self, kind: Overlay) {
        self.overlay.set(kind);
        self.repaint.notify();
    }
    fn pause(&self) {
        if self.overlay.get_untracked() == Overlay::None && !self.game.borrow().game_over {
            self.show(Overlay::Pause);
        }
    }
    /// New Game asks for the rules first; the picker starts the game.
    fn pick_difficulty(&self) {
        self.return_to.set(self.overlay.get_untracked());
        self.show(Overlay::Difficulty);
    }
    fn new_game(&self, difficulty: Difficulty) {
        self.game.borrow_mut().restart(difficulty);
        gamekit::clear(SAVE_KEY);
        self.return_to.set(Overlay::None);
        self.show(Overlay::None);
        self.cue(&cues::START);
    }
    fn undo(&self) {
        if self.game.borrow_mut().undo() {
            self.repaint.notify();
            self.cue(&UNDO);
        } else {
            self.cue(&cues::WARNING);
        }
    }
}

/// The 2048 screen.
pub fn twentyfortyeight_page() -> AnyPiece {
    let settings = gamekit::restore::<chrome::GameSettings>(SETTINGS_KEY).unwrap_or_default();
    let mut game = Game::new();
    if let Some(s) = gamekit::restore::<SaveState>(SAVE_KEY) {
        game.apply_save(s);
    }
    game.best = game
        .best
        .max(gamekit::restore::<i64>(RECORD_KEY).unwrap_or(0));
    let ui = Rc::new(Ui {
        game: Rc::new(RefCell::new(game)),
        repaint: Trigger::new(),
        overlay: Signal::new(Overlay::None),
        return_to: Cell::new(Overlay::None),
        sounds: Signal::new(settings.sounds),
        vibrations: Signal::new(settings.vibrations),
    });
    gamekit::autosave(SAVE_KEY, {
        let game = ui.game.clone();
        move || game.borrow().save_state()
    });
    gamekit::sounds(SOUNDS);
    Effect::new({
        let ui = ui.clone();
        move || {
            gamekit::save(
                SETTINGS_KEY,
                &chrome::GameSettings {
                    sounds: ui.sounds.get(),
                    vibrations: ui.vibrations.get(),
                    instructions_shown: true,
                },
            );
        }
    });
    if !settings.instructions_shown {
        ui.show(Overlay::Instructions);
    }
    gamekit::on_background(SAVE_KEY, {
        let ui = ui.clone();
        move || ui.pause()
    });

    let cv = {
        let (du, dr, ku) = (ui.clone(), ui.clone(), ui.clone());
        canvas(move |d, sz| {
            du.repaint.track();
            du.game.borrow_mut().field = sz;
            du.game.borrow().draw(d, sz);
        })
        .on_drag(move |dg| {
            if dr.overlay.get_untracked() != Overlay::None {
                return;
            }
            // The slide is PROVISIONAL while the finger is down: tiles track the drag
            // toward their post-move spots, slide back if the finger returns, and the move
            // commits only on release past the threshold.
            let mut g = dr.game.borrow_mut();
            match dg.phase {
                DragPhase::Began => g.clear_preview(),
                DragPhase::Ended => {
                    // A swipe long enough to commit with nothing to move buzzes back.
                    let mag = dg.translation.x.abs().max(dg.translation.y.abs());
                    let stuck = g.pending.is_none()
                        && g.anim.phase == Phase::Idle
                        && !g.game_over
                        && mag >= SLIDE_SPAN * COMMIT_FRACTION;
                    g.release_preview();
                    if stuck {
                        drop(g);
                        dr.cue(&cues::WARNING);
                        dr.repaint.notify();
                        return;
                    }
                }
                _ => {
                    let (tx, ty) = (dg.translation.x, dg.translation.y);
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
            dr.repaint.notify();
        })
        .on_key(move |k| {
            if ku.overlay.get_untracked() != Overlay::None {
                return;
            }
            let dir = match k.key.as_str() {
                "ArrowLeft" => 0,
                "ArrowRight" => 1,
                "ArrowUp" => 2,
                "ArrowDown" => 3,
                _ => return,
            };
            // A key press is a whole move: preview it fully, then release.
            let mut g = ku.game.borrow_mut();
            if g.anim.phase == Phase::Idle {
                g.clear_preview();
                g.preview(dir, 1.0);
                g.release_preview();
            }
            drop(g);
            ku.repaint.notify();
        })
        .id("tf-canvas")
        .grow()
    };

    // Mounted only while the game is live, so the display link goes idle behind a card.
    let clock = {
        let (cu, bu) = (ui.clone(), ui.clone());
        when(
            move || cu.overlay.get() == Overlay::None,
            move || twentyfortyeight_clock(bu.clone()),
        )
    };
    let pause = chrome::pause_button(tr("gk_pause"), "tf-pause", {
        let ui = ui.clone();
        move || {
            ui.pause();
            ui.cue(&cues::SELECT);
        }
    });
    // Easy's undo, beside the pause button, with its remaining count.
    let undo = {
        let (cu, du, tu) = (ui.clone(), ui.clone(), ui.clone());
        when(
            move || {
                cu.repaint.track();
                cu.game.borrow().difficulty.undo_allowed()
            },
            move || {
                let (du, tu) = (du.clone(), tu.clone());
                canvas(move |d, sz| {
                    du.repaint.track();
                    let g = du.game.borrow();
                    let on = g.can_undo();
                    let ink = Color::hex(0x77_6E_65).with_alpha(if on { 1.0 } else { 0.4 });
                    d.fill(
                        Shape::RoundedRect(Rect::new(0.0, 6.0, sz.width, sz.height - 12.0), 14.0),
                        Color::hex(0xBB_AD_A0).with_alpha(if on { 0.35 } else { 0.18 }),
                    );
                    d.text(
                        &tr("tf_undo").arg("n", g.undos_left as f64).format(),
                        Point::new(sz.width / 2.0, sz.height / 2.0),
                        TextStyle {
                            size: 13.0,
                            color: ink,
                            anchor: TextAnchor::CENTERED,
                            font: chrome::canvas_font(FontWeight::Bold),
                        },
                    );
                })
                .on_tap(move || tu.undo())
                .a11y(|a| a.label(tr("tf_undo_a11y").format()).role(Role::Button))
                .id("tf-undo")
                .frame(92.0, 44.0)
            },
        )
    };
    let corner = row((undo, pause)).spacing(4.0).padding(Insets {
        top: 0.0,
        leading: 0.0,
        bottom: 0.0,
        trailing: 4.0,
    });

    zstack((
        cv.overlay_aligned(Alignment::TopTrailing, corner),
        overlays(ui),
        clock,
    ))
    .any()
}

/// The game's frame consumer: the slide and pop tweens, and the haptics and cards a move earns.
fn twentyfortyeight_clock(ui: Rc<Ui>) -> impl Piece {
    frame_clock({
        move |dt| {
            let phase_before = ui.game.borrow().anim.phase;
            let (happenings, best, phase) = {
                let mut g = ui.game.borrow_mut();
                g.step(dt.as_secs_f64());
                (std::mem::take(&mut g.happenings), g.best, g.anim.phase)
            };
            for h in happenings {
                match h {
                    Happening::Moved(0) => ui.cue(&SLIDE),
                    Happening::Moved(v) if v < 64 => ui.cue(&MERGE_S),
                    Happening::Moved(v) if v < 512 => ui.cue(&MERGE_M),
                    Happening::Moved(_) => ui.cue(&MERGE_L),
                    Happening::Won => {
                        gamekit::save(RECORD_KEY, &best);
                        ui.cue(&WON);
                        ui.show(Overlay::Won);
                    }
                    Happening::GameOver => {
                        gamekit::save(RECORD_KEY, &best);
                        ui.cue(&cues::OVER_PUZZLE);
                        ui.show(Overlay::GameOver);
                    }
                }
            }
            // Turn-based: only repaint while an animation is in flight (idle frames do no work).
            if phase_before != Phase::Idle || phase != Phase::Idle {
                ui.repaint.notify();
            }
        }
    })
}

fn overlays(ui: Rc<Ui>) -> impl Piece {
    let scrim = {
        let u = ui.clone();
        when(move || u.overlay.get() != Overlay::None, chrome::scrim)
    };
    let (p, w, g, d, s, i) = (
        ui.clone(),
        ui.clone(),
        ui.clone(),
        ui.clone(),
        ui.clone(),
        ui.clone(),
    );
    let card = move |kind: Overlay, build: Rc<dyn Fn() -> AnyPiece>| {
        let u = ui.clone();
        when(move || u.overlay.get() == kind, move || build())
    };
    zstack((
        scrim,
        card(Overlay::Pause, Rc::new(move || pause_menu(p.clone()))),
        card(Overlay::Won, Rc::new(move || won_card(w.clone()))),
        card(
            Overlay::GameOver,
            Rc::new(move || game_over_card(g.clone())),
        ),
        card(
            Overlay::Difficulty,
            Rc::new(move || difficulty_picker(d.clone())),
        ),
        card(Overlay::Settings, Rc::new(move || settings_card(s.clone()))),
        card(
            Overlay::Instructions,
            Rc::new(move || instructions_card(i.clone())),
        ),
    ))
}

fn pause_menu(ui: Rc<Ui>) -> AnyPiece {
    let (u1, u2, u3, u4) = (ui.clone(), ui.clone(), ui.clone(), ui.clone());
    chrome::card(
        column((
            chrome::card_title(tr("gk_paused"), Color::WHITE),
            chrome::menu_button(tr("gk_resume"), chrome::GREEN, "tf-resume", move || {
                u1.show(Overlay::None)
            }),
            chrome::menu_button(tr("gk_new_game"), chrome::BLUE, "tf-new-game", move || {
                u2.pick_difficulty()
            }),
            chrome::menu_button(tr("gk_settings"), chrome::SLATE, "tf-settings", move || {
                u3.show(Overlay::Settings)
            }),
            chrome::menu_button(
                tr("gk_instructions"),
                chrome::INDIGO,
                "tf-instructions",
                move || u4.show(Overlay::Instructions),
            ),
            chrome::menu_button(tr("gk_quit"), chrome::RED, "tf-quit", || {
                nav_back();
            }),
        ))
        .spacing(14.0)
        .align(HAlign::Center),
    )
    .id("tf-pause-menu")
    .any()
}

fn won_card(ui: Rc<Ui>) -> AnyPiece {
    let score = ui.game.borrow().score;
    let (u1, u2) = (ui.clone(), ui);
    chrome::card(
        column((
            chrome::card_title(tr("tf_won_title"), chrome::GOLD),
            label(tr("tf_won_message"))
                .color(chrome::TEXT)
                .align(TextAlign::Center)
                .width(260.0),
            chrome::stat(
                tr("gk_score"),
                score.to_string(),
                Font::Title,
                Color::WHITE,
                "tf-won-score",
            ),
            chrome::menu_button(
                tr("tf_keep_going"),
                chrome::GREEN,
                "tf-keep-going",
                move || u1.show(Overlay::None),
            ),
            chrome::menu_button(tr("gk_new_game"), chrome::BLUE, "tf-new-game", move || {
                u2.pick_difficulty()
            }),
        ))
        .spacing(14.0)
        .align(HAlign::Center),
    )
    .id("tf-won")
    .any()
}

fn game_over_card(ui: Rc<Ui>) -> AnyPiece {
    let (score, best) = {
        let g = ui.game.borrow();
        (g.score, g.best)
    };
    let record = when(
        move || score >= best && score > 0,
        || {
            label(tr("gk_new_high_score"))
                .font(Font::Title3)
                .bold()
                .color(chrome::GOLD)
        },
    );
    let u = ui;
    chrome::card(
        column((
            chrome::card_title(tr("gk_game_over"), Color::WHITE),
            chrome::stat(
                tr("gk_score"),
                score.to_string(),
                Font::LargeTitle,
                chrome::GOLD,
                "tf-final-score",
            ),
            chrome::stat(
                tr("gk_best"),
                best.to_string(),
                Font::Title3,
                Color::WHITE,
                "tf-best",
            ),
            record,
            chrome::menu_button(
                tr("gk_play_again"),
                chrome::BLUE,
                "tf-play-again",
                move || u.pick_difficulty(),
            ),
            chrome::menu_button(tr("gk_quit"), chrome::RED, "tf-quit", || {
                nav_back();
            }),
        ))
        .spacing(14.0)
        .align(HAlign::Center),
    )
    .id("tf-game-over")
    .any()
}

fn difficulty_picker(ui: Rc<Ui>) -> AnyPiece {
    let current = ui.game.borrow().difficulty;
    let mut cards = Vec::new();
    for d in DIFFICULTIES {
        let u = ui.clone();
        let tint = d.accent();
        let check = when(
            move || d == current,
            move || {
                canvas(move |dr, sz| {
                    chrome::draw_check_glyph(
                        dr,
                        Point::new(sz.width / 2.0, sz.height / 2.0),
                        18.0,
                        tint,
                    );
                })
                .frame(24.0, 24.0)
            },
        );
        cards.push(
            row((
                column((
                    label(d.label())
                        .font(Font::Title3)
                        .bold()
                        .color(Color::WHITE),
                    label(d.detail())
                        .font(Font::Caption)
                        .color(chrome::TEXT_DIM),
                ))
                .spacing(4.0)
                .align(HAlign::Leading)
                .grow_w(),
                check,
            ))
            .align(VAlign::Center)
            .padding(14.0)
            .background(tint.with_alpha(0.18))
            .corner_radius(14.0)
            .on_tap(move || u.new_game(d))
            .a11y(move |a| a.label(d.label().format()).role(Role::Button))
            .id(d.id())
            .width(300.0)
            .any(),
        );
    }
    let u = ui;
    chrome::card(
        column((
            label(tr("tf_choose_difficulty"))
                .font(Font::Title2)
                .bold()
                .color(Color::WHITE),
            column(PieceVec(cards)).spacing(12.0),
            button(tr("gk_cancel"))
                .action(move || {
                    let back = u.return_to.replace(Overlay::None);
                    u.show(back);
                })
                .id("tf-cancel"),
        ))
        .spacing(16.0)
        .align(HAlign::Center),
    )
    .id("tf-difficulty-picker")
    .any()
}

fn settings_card(ui: Rc<Ui>) -> AnyPiece {
    let reset = {
        let u = ui.clone();
        button(tr("gk_reset_high_score"))
            .tint(chrome::RED)
            .action(move || {
                let u = u.clone();
                day_core::task(async move {
                    let sure = Alert::new(tr("gk_reset_high_score_title"))
                        .message(tr("gk_reset_high_score_message"))
                        .destructive(tr("gk_reset_confirm"), true)
                        .cancel(tr("gk_cancel"))
                        .present()
                        .await;
                    if sure == Some(true) {
                        u.game.borrow_mut().best = 0;
                        gamekit::clear(RECORD_KEY);
                        u.repaint.notify();
                    }
                });
            })
            .id("tf-reset-high-score")
    };
    let done = ui.clone();
    chrome::card(
        column((
            label(tr("gk_settings"))
                .font(Font::Title2)
                .bold()
                .color(Color::WHITE),
            chrome::section_heading(tr("nav_2048")),
            chrome::setting_row(tr("gk_sounds"), toggle(ui.sounds).id("tf-sounds").any()),
            chrome::setting_row(
                tr("gk_vibrations"),
                toggle(ui.vibrations).id("tf-vibrations").any(),
            ),
            chrome::section_heading(tr("gk_data")),
            reset,
            button(tr("gk_done"))
                .prominent()
                .action(move || done.show(Overlay::Pause))
                .id("tf-done"),
        ))
        .spacing(12.0)
        .align(HAlign::Center),
    )
    .id("tf-settings-card")
    .any()
}

fn instructions_card(ui: Rc<Ui>) -> AnyPiece {
    let live = ui.game.borrow().score > 0 && !ui.game.borrow().game_over;
    chrome::instructions_card(
        tr("nav_2048"),
        vec![
            Help::Para(tr("tf_help_intro")),
            Help::Heading(tr("tf_help_play")),
            Help::Para(tr("tf_help_play_1")),
            Help::Para(tr("tf_help_play_2")),
            Help::Para(tr("tf_help_play_3")),
            Help::Heading(tr("tf_help_goal")),
            Help::Para(tr("tf_help_goal_1")),
            Help::Heading(tr("gk_game_over_heading")),
            Help::Para(tr("tf_help_over_1")),
            Help::Heading(tr("tf_help_tips")),
            Help::Para(tr("tf_help_tips_1")),
            Help::Para(tr("tf_help_tips_2")),
            Help::Para(tr("tf_help_tips_3")),
        ],
        "tf-help-done",
        move || ui.show(if live { Overlay::Pause } else { Overlay::None }),
    )
    .id("tf-instructions-card")
    .any()
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
    fn easy_grants_three_undos_of_the_last_move() {
        let grid = [[2, 0, 0, 2], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]];
        let mut g = game_with(grid);
        g.restart(Difficulty::Easy);
        g.grid = grid;
        g.score = 0;
        assert!(!g.can_undo(), "nothing to take back yet");
        g.preview(0, 0.9);
        g.release_preview();
        settle(&mut g);
        assert_eq!(g.grid[0][0], 4);
        assert!(g.can_undo());
        assert!(g.undo());
        assert_eq!(g.grid, grid, "the move is taken back");
        assert_eq!(g.score, 0);
        assert_eq!(g.undos_left, UNDOS - 1);
        assert!(!g.undo(), "one undo per move");
        // Normal never grants one.
        let mut n = game_with(grid);
        n.preview(0, 0.9);
        n.release_preview();
        settle(&mut n);
        assert!(!n.can_undo());
    }

    #[test]
    fn hard_spawns_two_tiles_a_move_and_easy_only_twos() {
        let grid = [[2, 0, 0, 2], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]];
        let mut h = game_with(grid);
        h.restart(Difficulty::Hard);
        h.grid = grid;
        h.preview(0, 0.9);
        h.release_preview();
        settle(&mut h);
        let tiles = h.grid.iter().flatten().filter(|&&v| v != 0).count();
        assert_eq!(tiles, 3, "the merged tile plus two spawns");
        let mut e = Game::new();
        e.restart(Difficulty::Easy);
        for _ in 0..40 {
            e.grid = [[0; N]; N];
            e.spawn();
            assert!(e.grid.iter().flatten().all(|&v| v == 0 || v == 2));
        }
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
