//! Sirtet is a falling-tetromino stacker on an immediate-mode canvas, with gravity on Day's frame
//! clock (§8.4). A composite Day piece: pure composition over `day_pieces`. Tap rotates, horizontal
//! drag shifts, downward drag soft-drops.

use std::cell::RefCell;
use std::rc::Rc;

use day_fluent::tr;
use day_pieces::prelude::*;
use gamekit::chrome::cues::{self, with};
use gamekit::chrome::{self, Cue, Feedback, Help, Sfx, sfx};
use serde::{Deserialize, Serialize};

/// What a step did that the page reacts to (haptics, cards).
#[derive(Clone, Copy, PartialEq, Debug)]
enum Happening {
    /// A piece came to rest.
    Locked,
    /// This many lines cleared at once.
    Cleared(usize),
    GameOver,
}

/// The prefs keys this game persists under (gamekit; bump the game key on schema change).
const SAVE_KEY: &str = "sirtet.v1";
const RECORD_KEY: &str = "sirtet.best";
const SETTINGS_KEY: &str = "sirtet.settings";
/// The game's cover surface color (edge-to-edge behind the safe area).
pub const SURFACE: Color = Color::hex(0x0A_0A_14);

const COLS: usize = 10;
const ROWS: usize = 20;
/// The well takes the whole canvas: the header and the readouts are pieces above it now
/// (gamekit::chrome::game_frame), so nothing is reserved inside the drawing.
const TOP_UI: f64 = 0.0;
/// How long a line clear's call-out stays up (it fades over the last third).
const CLEAR_POPUP_LIFE: f64 = 1.0;

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
    /// The last clear's size and how long its SINGLE/DOUBLE/TRIPLE/SIRTET! call-out has left.
    clear_popup: Option<(usize, f64)>,
    game_over: bool,
    /// What the last step did that the page reacts to.
    happenings: Vec<Happening>,
    rng: Rng,
    // drag state
    drag_col0: i32,
    drag_x0: f64,
    drag_y_last: f64,
}

impl Game {
    fn new() -> Self {
        let seed = gamekit::seed();
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
            clear_popup: None,
            happenings: Vec::new(),
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
            self.happenings.push(Happening::GameOver);
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
            self.happenings.push(Happening::Locked);
            self.spawn();
        } else {
            self.happenings.push(Happening::Cleared(full.len()));
            self.clear_popup = Some((full.len(), CLEAR_POPUP_LIFE));
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
        if let Some((_, life)) = self.clear_popup.as_mut() {
            *life -= dt;
            if *life <= 0.0 {
                self.clear_popup = None;
            }
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
        ((self.field.width - bw) / 2.0, TOP_UI + self.top())
    }
    /// How far the header and well sit below the top: half the height they leave free, so a
    /// tall, narrow screen centers them rather than stacking them at the top.
    fn top(&self) -> f64 {
        let well = self.cell_size() * ROWS as f64;
        ((self.field.height - TOP_UI - well) / 2.0).max(0.0)
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

        // The score, the level and the lines are read from the row under the header now, and the
        // next piece from the preview beside them (see `info_bar`), so the well has the canvas.

        // The clear call-out: "SINGLE" / "DOUBLE" / "TRIPLE" / "SIRTET!", gold for four, glowing
        // blue, fading out over its last third above the bottom of the well.
        if let Some((n, life)) = self.clear_popup {
            let text = match n {
                1 => tr("st_clear_single"),
                2 => tr("st_clear_double"),
                3 => tr("st_clear_triple"),
                _ => tr("st_clear_sirtet"),
            }
            .format();
            let a = (life / (CLEAR_POPUP_LIFE / 3.0)).clamp(0.0, 1.0);
            let at = Point::new(sz.width / 2.0, oy + cs * ROWS as f64 - 100.0);
            let font = CanvasFont {
                family: None,
                weight: Some(FontWeight::Black),
                italic: false,
            };
            for (dx, dy) in [(-1.5, 0.0), (1.5, 0.0), (0.0, -1.5), (0.0, 1.5)] {
                d.text(
                    &text,
                    Point::new(at.x + dx, at.y + dy),
                    TextStyle {
                        size: 30.0,
                        color: Color::rgba(0.3, 0.5, 1.0, 0.55 * a),
                        anchor: TextAnchor::CENTERED,
                        font: font.clone(),
                    },
                );
            }
            d.text(
                &text,
                at,
                TextStyle {
                    size: 30.0,
                    color: if n >= 4 {
                        Color::rgba(1.0, 0.84, 0.25, a)
                    } else {
                        Color::rgba(1.0, 1.0, 1.0, a)
                    },
                    anchor: TextAnchor::CENTERED,
                    font,
                },
            );
        }
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
                    anchor: TextAnchor::CENTERED,
                    ..Default::default()
                },
            );
        }
    }
}

/// One well cell at grid position `(r, c)`: the rounded-square rendering shared by the
/// gameplay renderer and the home-tile preview.
fn draw_cell(d: &mut Draw, ox: f64, oy: f64, cs: f64, r: i32, c: i32, color: Color) {
    let x = ox + c as f64 * cs;
    let y = oy + r as f64 * cs;
    d.fill(
        Shape::RoundedRect(Rect::new(x + 1.0, y + 1.0, cs - 2.0, cs - 2.0), cs * 0.18),
        color,
    );
}

/// The home-grid tile preview: a mini well drawn with the same cell renderer, piece shapes,
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
        // A settled stack in the bottom rows: (row, col, kind); kinds pick the real colors.
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

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Overlay {
    None,
    Pause,
    GameOver,
    Settings,
    Instructions,
}

// Sounds, each with the haptic it plays beside (gamekit::chrome::Cue).
static ROTATE: Cue = with("sounds/sirtet/rotate.wav", cues::LIGHT_BEAT);
static LOCK: Cue = with("sounds/sirtet/lock.wav", cues::MEDIUM_BEAT);
/// One line ticks; two thud; three and four celebrate, four the most.
static CLEARS: [Cue; 4] = [
    with("sounds/sirtet/clear_1.wav", cues::LIGHT_BEAT),
    with("sounds/sirtet/clear_2.wav", chrome::THUD),
    with("sounds/sirtet/clear_3.wav", chrome::CELEBRATE),
    with("sounds/sirtet/clear_4.wav", chrome::BIG_CELEBRATE),
];

/// Every clip this game plays besides the shared ones (gamekit preloads both).
pub const SOUNDS: &[Sfx] = &[
    sfx("sounds/sirtet/rotate.wav"),
    sfx("sounds/sirtet/lock.wav"),
    sfx("sounds/sirtet/clear_1.wav"),
    sfx("sounds/sirtet/clear_2.wav"),
    sfx("sounds/sirtet/clear_3.wav"),
    sfx("sounds/sirtet/clear_4.wav"),
];

struct Ui {
    game: Rc<RefCell<Game>>,
    repaint: Trigger,
    overlay: Signal<Overlay>,
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
    fn new_game(&self) {
        self.game.borrow_mut().restart();
        gamekit::clear(SAVE_KEY);
        self.show(Overlay::None);
        self.cue(&cues::START);
    }
}

/// The Sirtet screen.
pub fn sirtet_page() -> AnyPiece {
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
    // The rules open by themselves on the first play; a restored game waits behind the pause
    // menu (the player was not holding the piece when it left).
    if !settings.instructions_shown {
        ui.show(Overlay::Instructions);
    } else if ui.game.borrow().score > 0 {
        ui.show(Overlay::Pause);
    }
    gamekit::on_background(SAVE_KEY, {
        let ui = ui.clone();
        move || ui.pause()
    });

    let cv = {
        let (du, tu, dr, ku) = (ui.clone(), ui.clone(), ui.clone(), ui.clone());
        canvas(move |d, sz| {
            du.repaint.track();
            du.game.borrow_mut().field = sz;
            du.game.borrow().draw(d, sz);
        })
        .on_tap(move || {
            if tu.overlay.get_untracked() != Overlay::None {
                return;
            }
            tu.game.borrow_mut().rotate();
            tu.repaint.notify();
            tu.cue(&ROTATE);
        })
        .on_drag(move |dg| {
            if dr.overlay.get_untracked() != Overlay::None {
                return;
            }
            let mut g = dr.game.borrow_mut();
            let cs = g.cell_size().max(1.0);
            match dg.phase {
                DragPhase::Began => {
                    g.drag_col0 = g.pcol;
                    g.drag_x0 = dg.location.x;
                    g.drag_y_last = dg.location.y;
                }
                _ => {
                    // Horizontal: snap to whole-column moves from the drag start.
                    let want = g.drag_col0 + ((dg.location.x - g.drag_x0) / cs).round() as i32;
                    let delta = want - g.pcol;
                    let before = g.pcol;
                    if delta != 0 {
                        let dir = delta.signum();
                        for _ in 0..delta.abs() {
                            g.move_dxy(dir);
                        }
                    }
                    let moved = g.pcol != before;
                    // Downward: soft-drop per cell of downward travel.
                    let mut dropped = false;
                    while dg.location.y - g.drag_y_last > cs {
                        g.drag_y_last += cs;
                        g.soft_drop();
                        dropped = true;
                    }
                    drop(g);
                    // A detent per column, a lighter one per soft-dropped row.
                    if moved || dropped {
                        dr.cue(&cues::TICK);
                    }
                    dr.repaint.notify();
                    return;
                }
            }
            drop(g);
            dr.repaint.notify();
        })
        .on_key(move |k| {
            if ku.overlay.get_untracked() != Overlay::None {
                return;
            }
            let mut g = ku.game.borrow_mut();
            let before = (g.rot, g.prow, g.pcol);
            match k.key.as_str() {
                "ArrowLeft" => g.move_dxy(-1),
                "ArrowRight" => g.move_dxy(1),
                "ArrowUp" => g.rotate(),
                "ArrowDown" => g.soft_drop(),
                _ => {}
            }
            let after = (g.rot, g.prow, g.pcol);
            drop(g);
            // The same sounds as the touch controls, for a key that moved the piece.
            if after.0 != before.0 {
                ku.cue(&ROTATE);
            } else if after != before {
                ku.cue(&cues::TICK);
            }
            ku.repaint.notify();
        })
        .id("st-canvas")
        .grow()
    };

    // Mounted only while the game is live, so the display link goes idle behind a card.
    let clock = {
        let (cu, bu) = (ui.clone(), ui.clone());
        when(
            move || cu.overlay.get() == Overlay::None,
            move || sirtet_clock(bu.clone()),
        )
    };
    let pu = ui.clone();
    let header = chrome::game_header(tr("nav_sirtet"), "st-pause", move || {
        pu.pause();
        pu.cue(&cues::SELECT);
    });
    zstack((
        chrome::game_frame(header, Some(info_bar(ui.clone())), cv.any(), None),
        overlays(ui),
        clock,
    ))
    .any()
}

/// The readouts under the header: score, level, lines, the best so far, and the piece coming
/// next. The preview stays drawn, since a shape is not something a label can say.
fn info_bar(ui: Rc<Ui>) -> AnyPiece {
    let (su, lu, nu, pu) = (ui.clone(), ui.clone(), ui.clone(), ui.clone());
    let score = chrome::info_stat(
        tr("gk_score"),
        move || {
            su.repaint.track();
            su.game.borrow().score.to_string()
        },
        Color::WHITE,
        "st-score",
    )
    .min_width(72.0)
    .any();
    let level = chrome::info_stat(
        tr("st_level"),
        move || {
            lu.repaint.track();
            lu.game.borrow().level().to_string()
        },
        Color::WHITE,
        "st-level",
    )
    .any();
    let lines = chrome::info_stat(
        tr("st_lines"),
        move || {
            nu.repaint.track();
            nu.game.borrow().lines.to_string()
        },
        Color::WHITE,
        "st-lines",
    )
    .any();
    // The preview is the fourth readout, captioned like the three beside it so it sits on the
    // same baseline and takes an equal share of the row instead of hanging off its end.
    let next = column((
        label(tr("st_next"))
            .font(Font::Caption)
            .color(chrome::TEXT_DIM),
        canvas(move |d, sz| {
            pu.repaint.track();
            let kind = pu.game.borrow().next;
            let mini = (sz.height / 3.0).min(sz.width / 5.0);
            let (nx, ny) = (sz.width / 2.0 - 2.0 * mini, sz.height / 2.0 - mini);
            for &(r, c) in &SHAPES[kind][0] {
                let x = nx + c as f64 * mini;
                let y = ny + r as f64 * mini;
                d.fill(
                    Shape::RoundedRect(Rect::new(x + 0.5, y + 0.5, mini - 1.0, mini - 1.0), 2.0),
                    kind_color(kind),
                );
            }
        })
        .a11y(|a| a.label(tr("st_next_a11y").format()))
        .id("st-next")
        .frame(64.0, 28.0),
    ))
    .spacing(2.0)
    .align(HAlign::Center)
    .any();
    // Four readouts is what fits a phone's width; the best score has the pause and game-over
    // cards to itself.
    chrome::info_row(vec![score, level, lines, next])
}

/// The game's frame consumer: gravity, clears, and the haptics and card a tick earns.
fn sirtet_clock(ui: Rc<Ui>) -> impl Piece {
    frame_clock({
        move |dt| {
            let happenings = {
                let mut g = ui.game.borrow_mut();
                g.step(dt.as_secs_f64());
                std::mem::take(&mut g.happenings)
            };
            for h in happenings {
                match h {
                    Happening::Locked => ui.cue(&LOCK),
                    Happening::Cleared(n) => ui.cue(&CLEARS[n.clamp(1, 4) - 1]),
                    Happening::GameOver => {
                        let best = ui.game.borrow().best;
                        gamekit::save(RECORD_KEY, &best);
                        ui.cue(&cues::OVER_ARCADE);
                        ui.show(Overlay::GameOver);
                    }
                }
            }
            ui.repaint.notify();
        }
    })
}

fn overlays(ui: Rc<Ui>) -> impl Piece {
    let scrim = {
        let u = ui.clone();
        when(move || u.overlay.get() != Overlay::None, chrome::scrim)
    };
    let (p, g, s, i) = (ui.clone(), ui.clone(), ui.clone(), ui.clone());
    let card = move |kind: Overlay, build: Rc<dyn Fn() -> AnyPiece>| {
        let u = ui.clone();
        when(move || u.overlay.get() == kind, move || build())
    };
    zstack((
        scrim,
        card(Overlay::Pause, Rc::new(move || pause_menu(p.clone()))),
        card(
            Overlay::GameOver,
            Rc::new(move || game_over_card(g.clone())),
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
            chrome::menu_button(tr("gk_resume"), chrome::GREEN, "st-resume", move || {
                u1.show(Overlay::None)
            }),
            chrome::menu_button(tr("gk_new_game"), chrome::BLUE, "st-new-game", move || {
                u2.new_game()
            }),
            chrome::menu_button(tr("gk_settings"), chrome::SLATE, "st-settings", move || {
                u3.show(Overlay::Settings)
            }),
            chrome::menu_button(
                tr("gk_instructions"),
                chrome::INDIGO,
                "st-instructions",
                move || u4.show(Overlay::Instructions),
            ),
            chrome::menu_button(tr("gk_quit"), chrome::RED, "st-quit", || {
                nav_back();
            }),
        ))
        .spacing(14.0)
        .align(HAlign::Center),
    )
    .id("st-pause-menu")
    .any()
}

fn game_over_card(ui: Rc<Ui>) -> AnyPiece {
    let (score, level, lines, best) = {
        let g = ui.game.borrow();
        (g.score, g.level(), g.lines, g.best)
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
                "st-final-score",
            ),
            row((
                chrome::stat(
                    tr("st_level"),
                    level.to_string(),
                    Font::Title3,
                    Color::WHITE,
                    "st-final-level",
                ),
                chrome::stat(
                    tr("st_lines"),
                    lines.to_string(),
                    Font::Title3,
                    Color::WHITE,
                    "st-final-lines",
                ),
                chrome::stat(
                    tr("gk_best"),
                    best.to_string(),
                    Font::Title3,
                    Color::WHITE,
                    "st-best",
                ),
            ))
            .spacing(24.0),
            record,
            chrome::menu_button(
                tr("gk_play_again"),
                chrome::BLUE,
                "st-play-again",
                move || u.new_game(),
            ),
            chrome::menu_button(tr("gk_quit"), chrome::RED, "st-quit", || {
                nav_back();
            }),
        ))
        .spacing(14.0)
        .align(HAlign::Center),
    )
    .id("st-game-over")
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
            .id("st-reset-high-score")
    };
    let done = ui.clone();
    chrome::card(
        column((
            label(tr("gk_settings"))
                .font(Font::Title2)
                .bold()
                .color(Color::WHITE),
            chrome::section_heading(tr("nav_sirtet")),
            chrome::setting_row(tr("gk_sounds"), toggle(ui.sounds).id("st-sounds").any()),
            chrome::setting_row(
                tr("gk_vibrations"),
                toggle(ui.vibrations).id("st-vibrations").any(),
            ),
            chrome::section_heading(tr("gk_data")),
            reset,
            button(tr("gk_done"))
                .prominent()
                .action(move || done.show(Overlay::Pause))
                .id("st-done"),
        ))
        .spacing(12.0)
        .align(HAlign::Center),
    )
    .id("st-settings-card")
    .any()
}

fn instructions_card(ui: Rc<Ui>) -> AnyPiece {
    let live = ui.game.borrow().score > 0 && !ui.game.borrow().game_over;
    chrome::instructions_card(
        tr("nav_sirtet"),
        vec![
            Help::Para(tr("st_help_intro")),
            Help::Heading(tr("st_help_play")),
            Help::Para(tr("st_help_play_1")),
            Help::Para(tr("st_help_play_2")),
            Help::Para(tr("st_help_play_3")),
            Help::Heading(tr("st_help_lines")),
            Help::Para(tr("st_help_lines_1")),
            Help::Para(tr("st_help_lines_2")),
            Help::Heading(tr("st_help_levels")),
            Help::Para(tr("st_help_levels_1")),
            Help::Heading(tr("gk_game_over_heading")),
            Help::Para(tr("st_help_over_1")),
        ],
        "st-help-done",
        move || ui.show(if live { Overlay::Pause } else { Overlay::None }),
    )
    .id("st-instructions-card")
    .any()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_line_clear_raises_its_call_out_then_fades() {
        let mut g = Game::new();
        // Fill the bottom row but its last cell, then lock a vertical I piece into the gap.
        for c in 0..COLS - 1 {
            g.grid[(ROWS - 1) * COLS + c] = 0;
        }
        g.kind = 0; // I
        g.rot = 1; // vertical: cells (0..4, 2) of the 4×4 box
        g.pcol = (COLS - 1) as i32 - 2;
        g.prow = (ROWS - 4) as i32;
        assert!(
            g.valid(g.kind, g.rot, g.prow, g.pcol),
            "the piece fits the gap"
        );
        g.lock();
        assert_eq!(g.clear_popup.map(|(n, _)| n), Some(1));
        assert_eq!(g.clearing.len(), 1);
        g.step(CLEAR_POPUP_LIFE + 0.1);
        assert!(g.clear_popup.is_none(), "the call-out expires");
    }
}
