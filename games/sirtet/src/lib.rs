//! Sirtet — a falling-tetromino stacker on an immediate-mode canvas, with gravity on Day's frame
//! clock (§8.4). A composite Day piece: pure composition over `day_pieces`. Tap rotates, horizontal
//! drag shifts, downward drag soft-drops.

use std::cell::RefCell;
use std::rc::Rc;

use day_fluent::tr;
use day_pieces::prelude::*;
use serde::{Deserialize, Serialize};

/// The prefs key this game's state persists under (gamekit; bump on schema change).
const SAVE_KEY: &str = "sirtet.v1";

const COLS: usize = 10;
const ROWS: usize = 20;
const TOP_UI: f64 = 96.0; // reserved header height above the well

/// 7 tetromino kinds × 4 rotations × 4 cells, as (row, col) offsets in a 4×4 box.
const SHAPES: [[[(i32, i32); 4]; 4]; 7] = [
    // I
    [
        [(1, 0), (1, 1), (1, 2), (1, 3)],
        [(0, 2), (1, 2), (2, 2), (3, 2)],
        [(2, 0), (2, 1), (2, 2), (2, 3)],
        [(0, 1), (1, 1), (2, 1), (3, 1)],
    ],
    // O
    [
        [(0, 1), (0, 2), (1, 1), (1, 2)],
        [(0, 1), (0, 2), (1, 1), (1, 2)],
        [(0, 1), (0, 2), (1, 1), (1, 2)],
        [(0, 1), (0, 2), (1, 1), (1, 2)],
    ],
    // T
    [
        [(0, 1), (1, 0), (1, 1), (1, 2)],
        [(0, 1), (1, 1), (1, 2), (2, 1)],
        [(1, 0), (1, 1), (1, 2), (2, 1)],
        [(0, 1), (1, 0), (1, 1), (2, 1)],
    ],
    // S
    [
        [(0, 1), (0, 2), (1, 0), (1, 1)],
        [(0, 1), (1, 1), (1, 2), (2, 2)],
        [(1, 1), (1, 2), (2, 0), (2, 1)],
        [(0, 0), (1, 0), (1, 1), (2, 1)],
    ],
    // Z
    [
        [(0, 0), (0, 1), (1, 1), (1, 2)],
        [(0, 2), (1, 1), (1, 2), (2, 1)],
        [(1, 0), (1, 1), (2, 1), (2, 2)],
        [(0, 1), (1, 0), (1, 1), (2, 0)],
    ],
    // J
    [
        [(0, 0), (1, 0), (1, 1), (1, 2)],
        [(0, 1), (0, 2), (1, 1), (2, 1)],
        [(1, 0), (1, 1), (1, 2), (2, 2)],
        [(0, 1), (1, 1), (2, 0), (2, 1)],
    ],
    // L
    [
        [(0, 2), (1, 0), (1, 1), (1, 2)],
        [(0, 1), (1, 1), (2, 1), (2, 2)],
        [(1, 0), (1, 1), (1, 2), (2, 0)],
        [(0, 0), (0, 1), (1, 1), (2, 1)],
    ],
];

fn kind_color(kind: usize) -> Color {
    match kind {
        0 => Color::hsl(186.0, 0.80, 0.55), // I cyan
        1 => Color::hsl(50.0, 0.85, 0.55),  // O yellow
        2 => Color::hsl(280.0, 0.55, 0.60), // T purple
        3 => Color::hsl(140.0, 0.65, 0.50), // S green
        4 => Color::hsl(0.0, 0.75, 0.58),   // Z red
        5 => Color::hsl(222.0, 0.70, 0.58), // J blue
        _ => Color::hsl(28.0, 0.85, 0.55),  // L orange
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
}

/// The durable subset of [`Game`] (gamekit save/restore): the well, active/next piece, and
/// scoring. Gravity accumulation, the clear flash, and drag state are session-only.
#[derive(Serialize, Deserialize)]
struct SaveState {
    grid: Vec<i8>,
    kind: usize,
    rot: usize,
    prow: i32,
    pcol: i32,
    bag: Vec<usize>,
    next: usize,
    score: i64,
    best: i64,
    lines: i64,
    clearing: Vec<usize>,
}

struct Game {
    field: Size,
    grid: [i8; ROWS * COLS], // -1 empty, else kind 0..6
    kind: usize,
    rot: usize,
    prow: i32,
    pcol: i32,
    bag: Vec<usize>,
    next: usize,
    score: i64,
    best: i64,
    lines: i64,
    grav_accum: f64,
    clearing: Vec<usize>, // rows flashing
    clear_timer: f64,
    game_over: bool,
    rng: Rng,
    // drag state
    drag_col0: i32,
    drag_x0: f64,
    drag_y_last: f64,
}

impl Game {
    fn new() -> Self {
        let seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0x2545_F491_4F6C_DD1D)
            | 1;
        let mut g = Game {
            field: Size::new(0.0, 0.0),
            grid: [-1; ROWS * COLS],
            kind: 0,
            rot: 0,
            prow: 0,
            pcol: 3,
            bag: Vec::new(),
            next: 0,
            score: 0,
            best: 0,
            lines: 0,
            grav_accum: 0.0,
            clearing: Vec::new(),
            clear_timer: 0.0,
            game_over: false,
            rng: Rng(seed),
            drag_col0: 0,
            drag_x0: 0.0,
            drag_y_last: 0.0,
        };
        g.next = g.draw_bag();
        g.spawn();
        g
    }

    fn draw_bag(&mut self) -> usize {
        if self.bag.is_empty() {
            self.bag = (0..7).collect();
            // Fisher–Yates
            for i in (1..self.bag.len()).rev() {
                let j = (self.rng.next() % (i as u64 + 1)) as usize;
                self.bag.swap(i, j);
            }
        }
        self.bag.pop().unwrap()
    }

    fn level(&self) -> i64 {
        (self.lines / 10 + 1).min(15)
    }
    fn interval(&self) -> f64 {
        (0.8 - (self.level() - 1) as f64 * 0.045).max(0.09)
    }

    fn cells(&self, kind: usize, rot: usize, prow: i32, pcol: i32) -> [(i32, i32); 4] {
        let mut out = [(0, 0); 4];
        for (i, &(dr, dc)) in SHAPES[kind][rot].iter().enumerate() {
            out[i] = (prow + dr, pcol + dc);
        }
        out
    }

    fn valid(&self, kind: usize, rot: usize, prow: i32, pcol: i32) -> bool {
        for (r, c) in self.cells(kind, rot, prow, pcol) {
            if c < 0 || c >= COLS as i32 || r >= ROWS as i32 {
                return false;
            }
            if r >= 0 && self.grid[r as usize * COLS + c as usize] != -1 {
                return false;
            }
        }
        true
    }

    fn spawn(&mut self) {
        self.kind = self.next;
        self.next = self.draw_bag();
        self.rot = 0;
        self.pcol = 3;
        self.prow = -1;
        // nudge down to first valid row
        if !self.valid(self.kind, self.rot, self.prow, self.pcol)
            && !self.valid(self.kind, self.rot, self.prow + 1, self.pcol)
        {
            self.game_over = true;
        }
    }

    fn lock(&mut self) {
        for (r, c) in self.cells(self.kind, self.rot, self.prow, self.pcol) {
            if r >= 0 && r < ROWS as i32 && c >= 0 && c < COLS as i32 {
                self.grid[r as usize * COLS + c as usize] = self.kind as i8;
            }
        }
        // Find full rows.
        let mut full = Vec::new();
        for r in 0..ROWS {
            if (0..COLS).all(|c| self.grid[r * COLS + c] != -1) {
                full.push(r);
            }
        }
        if full.is_empty() {
            self.spawn();
        } else {
            self.clearing = full;
            self.clear_timer = 0.28;
        }
    }

    fn commit_clears(&mut self) {
        let rows = std::mem::take(&mut self.clearing);
        let n = rows.len() as i64;
        // Remove rows top-down by rebuilding the grid.
        let mut new_grid = [-1i8; ROWS * COLS];
        let mut dst = ROWS as i32 - 1;
        for r in (0..ROWS).rev() {
            if rows.contains(&r) {
                continue;
            }
            for c in 0..COLS {
                new_grid[dst as usize * COLS + c] = self.grid[r * COLS + c];
            }
            dst -= 1;
        }
        self.grid = new_grid;
        let base = [0, 100, 300, 500, 800][n.clamp(0, 4) as usize];
        self.score += base * self.level();
        if self.score > self.best {
            self.best = self.score;
        }
        self.lines += n;
        self.spawn();
    }

    fn move_dxy(&mut self, dcol: i32) {
        if self.valid(self.kind, self.rot, self.prow, self.pcol + dcol) {
            self.pcol += dcol;
        }
    }

    fn rotate(&mut self) {
        if self.game_over || !self.clearing.is_empty() {
            return;
        }
        let nr = (self.rot + 1) % 4;
        for kick in [0, 1, -1, 2, -2] {
            if self.valid(self.kind, nr, self.prow, self.pcol + kick) {
                self.rot = nr;
                self.pcol += kick;
                return;
            }
        }
    }

    fn soft_drop(&mut self) {
        if self.valid(self.kind, self.rot, self.prow + 1, self.pcol) {
            self.prow += 1;
            self.score += 1;
        }
    }

    fn restart(&mut self) {
        self.grid = [-1; ROWS * COLS];
        self.score = 0;
        self.lines = 0;
        self.game_over = false;
        self.clearing.clear();
        self.grav_accum = 0.0;
        self.bag.clear();
        self.next = self.draw_bag();
        self.spawn();
    }

    /// Snapshot the durable state (gamekit). A finished game keeps only the best score.
    fn save_state(&self) -> SaveState {
        if self.game_over {
            let mut g = Game::new();
            g.best = self.best;
            return g.save_state();
        }
        SaveState {
            grid: self.grid.to_vec(),
            kind: self.kind,
            rot: self.rot,
            prow: self.prow,
            pcol: self.pcol,
            bag: self.bag.clone(),
            next: self.next,
            score: self.score,
            best: self.best,
            lines: self.lines,
            clearing: self.clearing.clone(),
        }
    }

    /// Rebuild from a snapshot. A save taken mid-flash restores with a tiny clear timer so
    /// the pending rows commit on the first tick.
    fn apply_save(&mut self, s: SaveState) {
        if s.grid.len() == ROWS * COLS {
            self.grid.copy_from_slice(&s.grid);
        }
        if s.kind < 7 && s.next < 7 && s.bag.iter().all(|&k| k < 7) {
            self.kind = s.kind;
            self.rot = s.rot % 4;
            self.prow = s.prow;
            self.pcol = s.pcol;
            self.bag = s.bag;
            self.next = s.next;
        }
        self.score = s.score;
        self.best = s.best.max(s.score);
        self.lines = s.lines;
        self.clearing = s.clearing.into_iter().filter(|&r| r < ROWS).collect();
        self.clear_timer = if self.clearing.is_empty() { 0.0 } else { 0.01 };
        self.game_over = false;
        self.grav_accum = 0.0;
    }

    fn ghost_row(&self) -> i32 {
        let mut r = self.prow;
        while self.valid(self.kind, self.rot, r + 1, self.pcol) {
            r += 1;
        }
        r
    }

    fn step(&mut self, dt: f64) {
        if self.game_over {
            return;
        }
        if !self.clearing.is_empty() {
            self.clear_timer -= dt;
            if self.clear_timer <= 0.0 {
                self.commit_clears();
            }
            return;
        }
        self.grav_accum += dt;
        if self.grav_accum >= self.interval() {
            self.grav_accum = 0.0;
            if self.valid(self.kind, self.rot, self.prow + 1, self.pcol) {
                self.prow += 1;
            } else {
                self.lock();
            }
        }
    }

    // --- geometry ---
    fn cell_size(&self) -> f64 {
        let w = self.field.width;
        let h = self.field.height;
        (w / COLS as f64).min((h - TOP_UI) / ROWS as f64).max(6.0)
    }
    fn well_origin(&self) -> (f64, f64) {
        let cs = self.cell_size();
        let bw = cs * COLS as f64;
        ((self.field.width - bw) / 2.0, TOP_UI)
    }

    fn draw(&self, d: &mut Draw, sz: Size) {
        d.fill(
            Shape::Rect(Rect::new(0.0, 0.0, sz.width, sz.height)),
            Color::hex(0x0A_0A_14),
        );
        let cs = self.cell_size();
        let (ox, oy) = self.well_origin();
        // Well background.
        d.fill(
            Shape::RoundedRect(
                Rect::new(
                    ox - 3.0,
                    oy - 3.0,
                    cs * COLS as f64 + 6.0,
                    cs * ROWS as f64 + 6.0,
                ),
                6.0,
            ),
            Color::hex(0x05_05_0C),
        );
        let cell =
            |d: &mut Draw, r: i32, c: i32, color: Color| draw_cell(d, ox, oy, cs, r, c, color);
        // Settled cells.
        for r in 0..ROWS {
            for c in 0..COLS {
                let v = self.grid[r * COLS + c];
                if self.clearing.contains(&r) {
                    cell(d, r as i32, c as i32, Color::WHITE);
                } else if v >= 0 {
                    cell(d, r as i32, c as i32, kind_color(v as usize));
                }
            }
        }
        if self.clearing.is_empty() && !self.game_over {
            // Ghost.
            let gr = self.ghost_row();
            let gc = kind_color(self.kind);
            for (r, c) in self.cells(self.kind, self.rot, gr, self.pcol) {
                if r >= 0 {
                    cell(d, r, c, Color::rgba(gc.r, gc.g, gc.b, 0.16));
                }
            }
            // Active piece.
            for (r, c) in self.cells(self.kind, self.rot, self.prow, self.pcol) {
                if r >= 0 {
                    cell(d, r, c, gc);
                }
            }
        }

        // Header. The leading gutter keeps the title clear of the cover's close button.
        let title = TextStyle {
            size: 26.0,
            color: Color::WHITE,
            anchor: TextAnchor::Leading,
        };
        d.text(
            &tr("st_title").format(),
            Point::new(ox.max(56.0), 18.0),
            title,
        );
        let stat = TextStyle {
            size: 15.0,
            color: Color::rgba(1.0, 1.0, 1.0, 0.8),
            anchor: TextAnchor::Leading,
        };
        d.text(
            &tr("st_score").arg("n", self.score).format(),
            Point::new(ox, 54.0),
            stat,
        );
        d.text(
            &tr("st_level_lines")
                .arg("level", self.level())
                .arg("lines", self.lines)
                .format(),
            Point::new(ox, 74.0),
            stat,
        );

        if self.game_over {
            d.fill(
                Shape::Rect(Rect::new(0.0, 0.0, sz.width, sz.height)),
                Color::rgba(0.0, 0.0, 0.05, 0.6),
            );
            d.text(
                &tr("st_game_over").format(),
                Point::new(sz.width / 2.0, sz.height / 2.0 - 16.0),
                TextStyle {
                    size: 32.0,
                    color: Color::WHITE,
                    anchor: TextAnchor::Centered,
                },
            );
            d.text(
                &tr("st_play_again").format(),
                Point::new(sz.width / 2.0, sz.height / 2.0 + 24.0),
                TextStyle {
                    size: 17.0,
                    color: Color::rgba(1.0, 1.0, 1.0, 0.8),
                    anchor: TextAnchor::Centered,
                },
            );
        }
    }
}

/// One well cell at grid position `(r, c)` — the rounded-square rendering shared by the
/// gameplay renderer and the home-tile preview.
fn draw_cell(d: &mut Draw, ox: f64, oy: f64, cs: f64, r: i32, c: i32, color: Color) {
    let x = ox + c as f64 * cs;
    let y = oy + r as f64 * cs;
    d.fill(
        Shape::RoundedRect(Rect::new(x + 1.0, y + 1.0, cs - 2.0, cs - 2.0), cs * 0.18),
        color,
    );
}

/// The home-grid tile preview: a mini well drawn with the SAME cell renderer, piece shapes,
/// and palette as gameplay ([`draw_cell`], [`SHAPES`], [`kind_color`]).
pub fn sirtet_preview() -> AnyPiece {
    canvas(|d, sz| {
        if sz.width < 4.0 || sz.height < 4.0 {
            return;
        }
        d.fill(
            Shape::Rect(Rect::new(0.0, 0.0, sz.width, sz.height)),
            Color::hex(0x0A_0A_14),
        );
        let cs = (sz.width / 8.0).min(sz.height / 8.0);
        let (ox, oy) = ((sz.width - cs * 8.0) / 2.0, (sz.height - cs * 8.0) / 2.0);
        // A settled stack in the bottom rows: (row, col, kind) — kinds pick the real colors.
        let settled: &[(i32, i32, usize)] = &[
            (7, 0, 5),
            (7, 1, 5),
            (7, 2, 3),
            (7, 3, 3),
            (7, 5, 1),
            (7, 6, 1),
            (7, 7, 4),
            (6, 0, 5),
            (6, 2, 3),
            (6, 3, 6),
            (6, 5, 1),
            (6, 6, 1),
            (5, 3, 6),
            (5, 2, 6),
        ];
        for &(r, c, k) in settled {
            draw_cell(d, ox, oy, cs, r, c, kind_color(k));
        }
        // A T piece falling mid-well, from the real shape table.
        for &(dr, dc) in &SHAPES[2][0] {
            draw_cell(d, ox, oy, cs, 1 + dr, 2 + dc, kind_color(2));
        }
    })
    .any()
}

/// The Sirtet screen.
pub fn sirtet_page() -> AnyPiece {
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
    .on_tap({
        let game = game.clone();
        move || {
            let mut g = game.borrow_mut();
            if g.game_over {
                g.restart();
            } else {
                g.rotate();
            }
            drop(g);
            repaint.notify();
        }
    })
    .on_drag({
        let game = game.clone();
        move |dr| {
            let mut g = game.borrow_mut();
            let cs = g.cell_size().max(1.0);
            match dr.phase {
                DragPhase::Began => {
                    g.drag_col0 = g.pcol;
                    g.drag_x0 = dr.location.x;
                    g.drag_y_last = dr.location.y;
                }
                _ => {
                    // Horizontal: snap to whole-column moves from the drag start.
                    let want = g.drag_col0 + ((dr.location.x - g.drag_x0) / cs).round() as i32;
                    let cur = g.pcol;
                    let delta = want - cur;
                    if delta != 0 {
                        let dir = delta.signum();
                        for _ in 0..delta.abs() {
                            g.move_dxy(dir);
                        }
                    }
                    // Downward: soft-drop per cell of downward travel.
                    while dr.location.y - g.drag_y_last > cs {
                        g.drag_y_last += cs;
                        g.soft_drop();
                    }
                }
            }
            drop(g);
            repaint.notify();
        }
    })
    .id("st-canvas")
    .grow();

    let clock = frame_clock({
        let game = game.clone();
        move |dt| {
            game.borrow_mut().step(dt.as_secs_f64());
            repaint.notify();
        }
    });

    zstack((cv, clock)).any()
}
