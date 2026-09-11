//! Sudoku — a classic 9×9 with notes, unlimited undo/redo, checkpoints, hints, pause, a
//! difficulty picker, settings, per-difficulty best times, and a how-to-play sheet, following
//! Faire-Games' Sudoku screen for screen. The board is built with Day's GRID layout
//! (docs/grid.md): 9 `grid_row`s of 9 interactive cell canvases; the keypad and action
//! buttons are canvases too, so the dark game surface reads the same on every toolkit; the
//! pause, solved, difficulty, settings, and instructions surfaces are in-page overlays with
//! native buttons. A hardware keyboard types a digit into the selected cell, clears it with 0
//! (and with Delete or Backspace where no menu bar owns them), and moves the selection with the
//! arrows; every canvas on the page hears the same keys. All user-facing strings resolve
//! through Fluent (`tr`, resource/locales/*/app.ftl).

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use day_fluent::tr;
use day_pieces::prelude::*;
use day_spec::{KeyEvent, LineCap, LineJoin, StrokeStyle};
use gamekit::chrome::cues::{self, with};
use gamekit::chrome::{self, Cue, Feedback, Sfx, sfx};

mod model;
use model::{DIFFICULTIES, Difficulty, Model, Records, Settings, fmt_time, idx};

/// The prefs keys this game persists under (gamekit; bump the puzzle key on schema change).
const SAVE_KEY: &str = "sudoku.v2";
const RECORDS_KEY: &str = "sudoku.records";
const SETTINGS_KEY: &str = "sudoku.settings";

const CELL: f64 = 38.0;
const BOARD_PAD: f64 = 4.0;
const BOARD: f64 = CELL * 9.0 + BOARD_PAD * 2.0;
const KEY_W: f64 = 64.0;
const KEY_H: f64 = 56.0;
const KEY_GAP: f64 = 6.0;
const ACTION_W: f64 = 64.0;
/// Two action buttons stacked with an 8pt gap span the keypad's height.
const ACTION_H: f64 = (KEY_H * 3.0 + KEY_GAP * 2.0 - 8.0) / 2.0;
const MENU_W: f64 = 180.0;

// Palette (Faire's night-blue look).
const BG_TOP: Color = Color::rgb(0.06, 0.07, 0.14);
const BG_BOTTOM: Color = Color::rgb(0.04, 0.04, 0.10);
const BOARD_BG: Color = Color::rgb(0.10, 0.12, 0.22);
const CELL_BG: Color = Color::rgb(0.08, 0.10, 0.18);
const SEL_BG: Color = Color::rgba(0.25, 0.45, 0.85, 0.65);
const SAME_BG: Color = Color::rgba(0.20, 0.40, 0.75, 0.40);
const PEER_BG: Color = Color::rgba(0.14, 0.18, 0.32, 0.70);
const LINE_THIN: Color = Color::rgba(1.0, 1.0, 1.0, 0.12);
const LINE_THICK: Color = Color::rgba(1.0, 1.0, 1.0, 0.55);
const BOARD_RIM: Color = Color::rgba(1.0, 1.0, 1.0, 0.35);
const INK_GIVEN: Color = Color::rgba(1.0, 1.0, 1.0, 0.62);
const INK_USER: Color = Color::rgb(0.65, 0.85, 1.0);
const INK_PROVISIONAL: Color = Color::rgb(1.0, 0.78, 0.40);
const INK_FILLED: Color = Color::rgb(0.45, 0.92, 0.55);
const INK_WRONG: Color = Color::rgb(1.0, 0.45, 0.45);
const NOTE: Color = Color::rgba(1.0, 1.0, 1.0, 0.55);
const NOTE_PROVISIONAL: Color = Color::rgba(1.0, 0.78, 0.40, 0.85);
const TEXT: Color = Color::rgba(1.0, 1.0, 1.0, 0.85);
const TEXT_DIM: Color = Color::rgba(1.0, 1.0, 1.0, 0.55);
const TIME_TINT: Color = Color::rgb(0.60, 0.75, 0.95);
const OVER_TINT: Color = Color::rgb(1.0, 0.55, 0.55);
const CARD: Color = Color::rgb(0.08, 0.08, 0.18);
const SCRIM: Color = Color::rgba(0.0, 0.0, 0.0, 0.72);
const KEY_BLUE: Color = Color::rgb(0.30, 0.55, 0.95);
const GOLD: Color = Color::rgb(1.0, 0.84, 0.25);
const GREEN: Color = Color::rgb(0.30, 0.70, 0.40);
const RED: Color = Color::rgb(0.85, 0.30, 0.30);
const SLATE: Color = Color::rgb(0.30, 0.40, 0.60);
const INDIGO: Color = Color::rgb(0.40, 0.40, 0.70);
const AMBER: Color = Color::rgb(0.70, 0.40, 0.10);

/// The game's cover surface color (edge-to-edge behind the safe area).
pub const SURFACE: Color = BG_BOTTOM;

type Game = Rc<RefCell<Model>>;

/// Each difficulty's accent (the status pill, the picker card, the check mark).
fn accent(d: Difficulty) -> Color {
    match d {
        Difficulty::Easy => Color::rgb(0.35, 0.75, 0.45),
        Difficulty::Medium => Color::rgb(0.30, 0.60, 0.95),
        Difficulty::Hard => Color::rgb(0.95, 0.55, 0.15),
        Difficulty::Expert => Color::rgb(0.90, 0.30, 0.40),
    }
}

/// The difficulty display names, as LITERAL `tr` keys so `day lint` tracks their coverage.
fn difficulty_label(d: Difficulty) -> day_fluent::LocalizedText {
    match d {
        Difficulty::Easy => tr("su_easy"),
        Difficulty::Medium => tr("su_medium"),
        Difficulty::Hard => tr("su_hard"),
        Difficulty::Expert => tr("su_expert"),
    }
}

/// The picker's one-line description of each difficulty.
fn difficulty_detail(d: Difficulty) -> day_fluent::LocalizedText {
    match d {
        Difficulty::Easy => tr("su_detail_easy"),
        Difficulty::Medium => tr("su_detail_medium"),
        Difficulty::Hard => tr("su_detail_hard"),
        Difficulty::Expert => tr("su_detail_expert"),
    }
}

fn difficulty_id(d: Difficulty) -> &'static str {
    match d {
        Difficulty::Easy => "su-diff-easy",
        Difficulty::Medium => "su-diff-medium",
        Difficulty::Hard => "su-diff-hard",
        Difficulty::Expert => "su-diff-expert",
    }
}

fn canvas_font(weight: FontWeight) -> CanvasFont {
    CanvasFont {
        family: None,
        weight: Some(weight),
        italic: false,
    }
}

/// The in-page surfaces that sit over the board.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Overlay {
    None,
    Pause,
    Solved,
    Difficulty,
    Settings,
    Instructions,
}

// Sounds, each with the haptic it plays beside (gamekit::chrome::Cue).
static PLACE: Cue = with("sounds/sudoku/place.wav", cues::MEDIUM_BEAT);
/// A digit taken back out, by the keypad, a repeated digit, or the delete keys.
static CLEAR: Cue = with("sounds/sudoku/clear.wav", cues::LIGHT_BEAT);
static NOTES: Cue = with("sounds/sudoku/notes.wav", cues::TICK_BEAT);
static HINT: Cue = with("sounds/shared/hint.wav", cues::MEDIUM_BEAT);
static UNDO: Cue = with("sounds/sudoku/undo.wav", cues::LIGHT_BEAT);
static REDO: Cue = with("sounds/sudoku/redo.wav", cues::LIGHT_BEAT);
static CHECKPOINT: Cue = with("sounds/sudoku/checkpoint.wav", cues::TICK_BEAT);
static SOLVED: Cue = with("sounds/sudoku/solved.wav", chrome::BIG_CELEBRATE);

/// Every clip this game plays besides the shared ones (gamekit preloads both).
pub const SOUNDS: &[Sfx] = &[
    sfx("sounds/sudoku/place.wav"),
    sfx("sounds/sudoku/clear.wav"),
    sfx("sounds/sudoku/notes.wav"),
    sfx("sounds/sudoku/undo.wav"),
    sfx("sounds/sudoku/redo.wav"),
    sfx("sounds/sudoku/checkpoint.wav"),
    sfx("sounds/sudoku/solved.wav"),
];

/// Everything the page's closures share: the model, the two invalidation triggers, the
/// overlay state, and the settings signals.
struct Ui {
    game: Game,
    /// Invalidates the cells, keypad, and buttons on every state edit.
    board: Trigger,
    /// Invalidates the time pill once a second, so the 81 cell bindings stay idle.
    clock: Trigger,
    overlay: Signal<Overlay>,
    /// Where Cancel/Done returns to: the pause menu, the solved card, or the board.
    return_to: Cell<Overlay>,
    sounds: Signal<bool>,
    vibrations: Signal<bool>,
    default_difficulty: Signal<usize>,
    /// Whether the page's backdrop holds the keyboard. It takes it as the page mounts, and
    /// `show` hands it back whenever the board is uncovered, since a card's buttons can take it.
    board_focus: Signal<bool>,
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

    /// Run an edit against the model, then react to what it did: a solve records the time,
    /// opens the solved card, and celebrates; everything else repaints.
    fn edit(&self, f: impl FnOnce(&mut Model)) {
        let was_complete = self.game.borrow().complete;
        f(&mut self.game.borrow_mut());
        let (complete, records) = {
            let g = self.game.borrow();
            (g.complete, g.records.clone())
        };
        if complete && !was_complete {
            gamekit::save(RECORDS_KEY, &records);
            self.show(Overlay::Solved);
            self.cue(&SOLVED);
        }
        self.board.notify();
    }

    /// Present `kind` (or clear with `Overlay::None`). The clock stops while any surface
    /// covers the board of a live game, and uncovering it hands the keyboard back to the page.
    fn show(&self, kind: Overlay) {
        {
            let mut g = self.game.borrow_mut();
            if !g.locked() {
                g.paused = kind != Overlay::None;
            }
        }
        self.overlay.set(kind);
        self.board.notify();
        if kind == Overlay::None {
            self.board_focus.set(true);
        }
    }

    /// Present a secondary surface (the picker, settings, instructions) and remember what to
    /// come back to.
    fn push(&self, kind: Overlay) {
        self.return_to.set(self.overlay.get_untracked());
        self.show(kind);
    }

    fn pop(&self) {
        let back = self.return_to.replace(Overlay::None);
        self.show(back);
    }

    fn new_game(&self, d: Difficulty) {
        self.default_difficulty.set(d.index());
        self.game.borrow_mut().new_game(d);
        gamekit::save(SAVE_KEY, &self.game.borrow().save_state());
        self.return_to.set(Overlay::None);
        self.show(Overlay::None);
        self.cue(&cues::START);
    }

    /// Enter `digit` into the selected cell: the keypad's action, and a typed digit's. A digit
    /// the cell already holds clears it, with the lighter tick.
    fn enter(&self, digit: u8) {
        let clears = self.game.borrow().clears_with(digit);
        let mut placed = false;
        self.edit(|g| placed = g.place(digit));
        if placed {
            self.cue(if clears { &CLEAR } else { &PLACE });
        }
    }

    fn erase(&self) {
        let mut erased = false;
        self.edit(|g| erased = g.erase());
        if erased {
            self.cue(&CLEAR);
        }
    }

    /// A hardware key, heard by whichever of the page's canvases has focus (docs/menus.md): a
    /// digit fills the selected cell, 0 and the delete keys clear it, and the arrows move the
    /// selection. Menu-bar platforms keep Delete and Backspace for their menus, so 0 is the
    /// clear key every keyboard delivers.
    fn key(&self, k: &KeyEvent) {
        if self.overlay.get_untracked() != Overlay::None {
            return;
        }
        if let Some(digit) = k.digit() {
            if digit == 0 {
                self.erase();
            } else {
                self.enter(digit);
            }
            return;
        }
        let (dr, dc) = match k.key.as_str() {
            "ArrowLeft" => (0, -1),
            "ArrowRight" => (0, 1),
            "ArrowUp" => (-1, 0),
            "ArrowDown" => (1, 0),
            "Delete" | "Backspace" => {
                self.erase();
                return;
            }
            _ => return,
        };
        let before = self.game.borrow().selected;
        self.edit(|g| g.move_selection(dr, dc));
        if self.game.borrow().selected != before {
            self.cue(&cues::TICK);
        }
    }

    fn settings(&self) -> Settings {
        Settings {
            sounds: self.sounds.get_untracked(),
            vibrations: self.vibrations.get_untracked(),
            default_difficulty: Difficulty::from_index(self.default_difficulty.get_untracked()),
            instructions_shown: true,
        }
    }
}

// ---------------------------------------------------------------------------
// Drawing shared by the board, the keypad, and the home-tile preview
// ---------------------------------------------------------------------------

/// The palette for one cell's digit.
fn cell_ink(g: &Model, i: usize) -> Color {
    if g.given_up && g.given_up_fill[i] {
        INK_FILLED
    } else if g.is_user_wrong(i) || g.is_obvious_mistake(i) {
        INK_WRONG
    } else if g.original[i] {
        INK_GIVEN
    } else if g.provisional[i] {
        INK_PROVISIONAL
    } else {
        INK_USER
    }
}

/// Highlight: the selected cell, the same digit elsewhere (not in Expert), then its peers.
fn cell_background(g: &Model, i: usize) -> Color {
    let Some(sel) = g.selected else {
        return CELL_BG;
    };
    if sel == i {
        return SEL_BG;
    }
    let v = g.values[sel];
    if v != 0 && g.values[i] == v && g.difficulty.highlights_same_digit() {
        return SAME_BG;
    }
    if Model::is_peer(sel, i) {
        return PEER_BG;
    }
    CELL_BG
}

/// One board cell's full rendering — background, box lines, value or pencil marks.
#[allow(clippy::too_many_arguments)]
fn draw_cell(
    d: &mut Draw,
    sz: Size,
    row: usize,
    col: usize,
    value: u8,
    notes: u16,
    bg: Color,
    ink: Color,
    given: bool,
    provisional: bool,
) {
    let (w, h) = (sz.width, sz.height);
    d.fill(Shape::Rect(Rect::new(0.0, 0.0, w, h)), bg);
    // Interior lines only: thick on the 3×3 boundaries, hairline elsewhere; the board's
    // rounded rim frames the outside.
    if col > 0 {
        let thick = col.is_multiple_of(3);
        let lw = if thick { 2.0 } else { 0.5 };
        d.fill(
            Shape::Rect(Rect::new(0.0, 0.0, lw, h)),
            if thick { LINE_THICK } else { LINE_THIN },
        );
    }
    if row > 0 {
        let thick = row.is_multiple_of(3);
        let lw = if thick { 2.0 } else { 0.5 };
        d.fill(
            Shape::Rect(Rect::new(0.0, 0.0, w, lw)),
            if thick { LINE_THICK } else { LINE_THIN },
        );
    }
    if value != 0 {
        d.text(
            &value.to_string(),
            Point::new(w / 2.0, h / 2.0),
            TextStyle {
                size: h * 0.55,
                color: ink,
                anchor: TextAnchor::CENTERED,
                font: canvas_font(if given {
                    FontWeight::Black
                } else {
                    FontWeight::Semibold
                }),
            },
        );
    } else if notes != 0 {
        let color = if provisional { NOTE_PROVISIONAL } else { NOTE };
        for digit in 1..=9u8 {
            if notes & (1 << digit) != 0 {
                let (nc, nr) = (((digit - 1) % 3) as f64, ((digit - 1) / 3) as f64);
                d.text(
                    &digit.to_string(),
                    Point::new(w * (0.5 + nc) / 3.0, h * (0.5 + nr) / 3.0),
                    TextStyle {
                        size: h * 0.24,
                        color,
                        anchor: TextAnchor::CENTERED,
                        font: canvas_font(FontWeight::Medium),
                    },
                );
            }
        }
    }
}

/// The home-grid tile preview: nine mini boxes of canonical digits on the game's gradient,
/// drawn with the same palette as gameplay.
pub fn sudoku_preview() -> AnyPiece {
    const PATTERN: [&str; 9] = [
        "5..678.12",
        "67..953.8",
        ".983.256.",
        ".597.1.23",
        "4.6.5.7..",
        "71..2485.",
        ".61.3.284",
        ".8.41.6..",
        "3.5.86.79",
    ];
    canvas(|d, sz| {
        if sz.width < 4.0 || sz.height < 4.0 {
            return;
        }
        d.fill(
            Shape::Rect(Rect::new(0.0, 0.0, sz.width, sz.height)),
            LinearGradient::new(
                UnitPoint::TOP_LEADING,
                UnitPoint::BOTTOM_TRAILING,
                vec![
                    (0.0, Color::rgb(0.10, 0.15, 0.30)),
                    (1.0, Color::rgb(0.05, 0.08, 0.18)),
                ],
            ),
        );
        let pad = sz.width * 0.06;
        let side = sz.width.min(sz.height) - pad * 2.0;
        let gap = side * 0.02;
        let boxw = (side - gap * 2.0) / 3.0;
        let (ox, oy) = ((sz.width - side) / 2.0, (sz.height - side) / 2.0);
        let palette = [Color::WHITE, INK_USER, Color::rgb(1.0, 0.75, 0.55)];
        for (b, digits) in PATTERN.iter().enumerate() {
            let (br, bc) = ((b / 3) as f64, (b % 3) as f64);
            let x = ox + bc * (boxw + gap);
            let y = oy + br * (boxw + gap);
            let rect = Rect::new(x, y, boxw, boxw);
            d.fill(
                Shape::RoundedRect(rect, 3.0),
                Color::rgba(1.0, 1.0, 1.0, 0.04),
            );
            d.stroke(Shape::RoundedRect(rect, 3.0), BOARD_RIM, 0.5);
            let cell = boxw / 3.0;
            for (k, ch) in digits.bytes().enumerate() {
                if ch == b'.' {
                    continue;
                }
                let (r, c) = ((k / 3) as f64, (k % 3) as f64);
                let digit = (ch - b'0') as usize;
                d.text(
                    &(ch as char).to_string(),
                    Point::new(x + (c + 0.5) * cell, y + (r + 0.5) * cell),
                    TextStyle {
                        size: cell * 0.72,
                        color: palette[(b + digit) % palette.len()],
                        anchor: TextAnchor::CENTERED,
                        font: canvas_font(FontWeight::Heavy),
                    },
                );
            }
        }
    })
    .any()
}

// ---------------------------------------------------------------------------
// Glyphs for the canvas-drawn buttons
// ---------------------------------------------------------------------------

#[derive(Clone, Copy)]
enum Glyph {
    Pencil,
    Bulb,
    Undo,
    Redo,
    Flag,
    Check,
    Cross,
    Pause,
}

/// Draw `glyph` centered at `c` inside a `size`-point square, in `color`.
fn draw_glyph(d: &mut Draw, glyph: Glyph, c: Point, size: f64, color: Color) {
    let s = size / 2.0;
    let stroke = (size * 0.12).max(1.5);
    let style = StrokeStyle {
        width: stroke,
        cap: LineCap::Round,
        join: LineJoin::Round,
        ..Default::default()
    };
    let p = |x: f64, y: f64| Point::new(c.x + x * s, c.y + y * s);
    match glyph {
        Glyph::Pencil => {
            d.stroke_styled(
                Shape::Line(p(-0.7, 0.7), p(0.5, -0.5)),
                color,
                style.clone(),
            );
            d.stroke_styled(Shape::Line(p(0.5, -0.5), p(0.8, -0.8)), color, style);
            d.fill(
                Shape::Polygon(vec![p(-0.7, 0.7), p(-0.95, 0.95), p(-0.45, 0.95)]),
                color,
            );
        }
        Glyph::Bulb => {
            d.stroke_styled(
                Shape::Ellipse(Rect::new(c.x - 0.55 * s, c.y - 0.9 * s, 1.1 * s, 1.1 * s)),
                color,
                style.clone(),
            );
            d.stroke_styled(
                Shape::Line(p(-0.3, 0.55), p(0.3, 0.55)),
                color,
                style.clone(),
            );
            d.stroke_styled(Shape::Line(p(-0.22, 0.9), p(0.22, 0.9)), color, style);
        }
        Glyph::Undo | Glyph::Redo => {
            let m = if matches!(glyph, Glyph::Undo) {
                1.0
            } else {
                -1.0
            };
            d.stroke_styled(
                Shape::Arc {
                    rect: Rect::new(c.x - 0.7 * s, c.y - 0.55 * s, 1.4 * s, 1.4 * s),
                    start_deg: if m > 0.0 { 200.0 } else { 340.0 },
                    sweep_deg: 220.0 * m,
                },
                color,
                style,
            );
            d.fill(
                Shape::Polygon(vec![
                    p(-0.95 * m, -0.05),
                    p(-0.35 * m, -0.05),
                    p(-0.65 * m, -0.7),
                ]),
                color,
            );
        }
        Glyph::Flag => {
            d.stroke_styled(Shape::Line(p(-0.6, 0.95), p(-0.6, -0.9)), color, style);
            d.fill(
                Shape::Polygon(vec![p(-0.6, -0.9), p(0.75, -0.55), p(-0.6, -0.2)]),
                color,
            );
        }
        Glyph::Check => {
            d.stroke_styled(
                PathBuilder::new()
                    .move_to(p(-0.8, 0.05))
                    .line_to(p(-0.25, 0.65))
                    .line_to(p(0.85, -0.6))
                    .build(),
                color,
                style,
            );
        }
        Glyph::Cross => {
            d.stroke_styled(
                Shape::Line(p(-0.7, -0.7), p(0.7, 0.7)),
                color,
                style.clone(),
            );
            d.stroke_styled(Shape::Line(p(-0.7, 0.7), p(0.7, -0.7)), color, style);
        }
        Glyph::Pause => {
            d.stroke_styled(
                Shape::Ellipse(Rect::new(c.x - s, c.y - s, 2.0 * s, 2.0 * s)),
                color,
                style.clone(),
            );
            d.stroke_styled(
                Shape::Line(p(-0.25, -0.4), p(-0.25, 0.4)),
                color,
                style.clone(),
            );
            d.stroke_styled(Shape::Line(p(0.25, -0.4), p(0.25, 0.4)), color, style);
        }
    }
}

// ---------------------------------------------------------------------------
// The page
// ---------------------------------------------------------------------------

/// The Sudoku screen.
pub fn sudoku_page() -> AnyPiece {
    let settings = gamekit::restore::<Settings>(SETTINGS_KEY).unwrap_or_default();
    let mut model = Model::new(gamekit::seed(), settings.default_difficulty);
    model.records = gamekit::restore::<Records>(RECORDS_KEY).unwrap_or_default();
    if let Some(s) = gamekit::restore::<model::SaveState>(SAVE_KEY)
        && !model.apply_save(s)
    {
        gamekit::clear(SAVE_KEY);
    }
    let game: Game = Rc::new(RefCell::new(model));
    gamekit::autosave(SAVE_KEY, {
        let game = game.clone();
        move || game.borrow().save_state()
    });

    let ui = Rc::new(Ui {
        game: game.clone(),
        board: Trigger::new(),
        clock: Trigger::new(),
        overlay: Signal::new(Overlay::None),
        return_to: Cell::new(Overlay::None),
        sounds: Signal::new(settings.sounds),
        vibrations: Signal::new(settings.vibrations),
        default_difficulty: Signal::new(settings.default_difficulty.index()),
        board_focus: Signal::new(true),
    });
    gamekit::sounds(SOUNDS);

    // Settings persist as they change; the first run also records that the instructions
    // have been offered.
    Effect::new({
        let ui = ui.clone();
        move || {
            ui.sounds.track();
            ui.vibrations.track();
            ui.default_difficulty.track();
            gamekit::save(SETTINGS_KEY, &ui.settings());
        }
    });
    if !settings.instructions_shown {
        ui.push(Overlay::Instructions);
    }

    // Leaving the foreground pauses the clock (gamekit saves right after).
    gamekit::on_background(SAVE_KEY, {
        let ui = ui.clone();
        move || {
            if ui.overlay.get_untracked() == Overlay::None && !ui.game.borrow().locked() {
                ui.show(Overlay::Pause);
            }
        }
    });

    let ticker = frame_clock({
        let ui = ui.clone();
        move |dt| {
            let mut g = ui.game.borrow_mut();
            let before = g.elapsed as u64;
            g.tick(dt.as_secs_f64());
            let after = g.elapsed as u64;
            drop(g);
            if before != after {
                ui.clock.notify();
            }
        }
    });

    // The keyboard's home: the backdrop takes focus as the page mounts and again whenever a
    // card closes, and every canvas a press can land on hears the same keys, so a click
    // anywhere on the page keeps them coming.
    let backdrop = canvas(|d, sz| {
        d.fill(
            Shape::Rect(Rect::new(0.0, 0.0, sz.width, sz.height)),
            LinearGradient::new(
                UnitPoint::TOP,
                UnitPoint::BOTTOM,
                vec![(0.0, BG_TOP), (1.0, BG_BOTTOM)],
            ),
        );
    })
    .on_key(keys(&ui))
    .focused(ui.board_focus)
    .id("su-backdrop")
    .grow();

    let content = column((
        hud(ui.clone()),
        status_bar(ui.clone()),
        board_grid(ui.clone()),
        control_pad(ui.clone()),
    ))
    .spacing(12.0)
    .align(HAlign::Center)
    .padding(Insets {
        top: 8.0,
        leading: 12.0,
        bottom: 16.0,
        trailing: 12.0,
    });
    // The scroll gives its content at least the window's height, so the stack centers the column
    // both ways: mid-window on a desktop, with even space above and below the board, and from
    // the top once the column is taller than the window and scrolls.
    let page = scroll(zstack((content,)).align(Alignment::Center))
        .grow()
        .id("su-page");

    zstack((backdrop, page, overlays(ui), ticker)).any()
}

/// The page's key handler, for every canvas a press can focus (docs/menus.md).
fn keys(ui: &Rc<Ui>) -> impl Fn(&KeyEvent) + 'static {
    let ui = ui.clone();
    move |k| ui.key(k)
}

/// Title and pause button; the leading gutter clears the cover's close button.
fn hud(ui: Rc<Ui>) -> impl Piece {
    let pause = canvas(|d, sz| {
        draw_glyph(
            d,
            Glyph::Pause,
            Point::new(sz.width / 2.0, sz.height / 2.0),
            24.0,
            Color::rgba(1.0, 1.0, 1.0, 0.7),
        );
    })
    .on_key(keys(&ui))
    .on_tap(move || {
        if ui.overlay.get_untracked() == Overlay::None {
            ui.show(Overlay::Pause);
            ui.cue(&cues::SELECT);
        }
    })
    .a11y(|a| a.label(tr("gk_pause").format()).role(Role::Button))
    .id("su-pause")
    .frame(44.0, 44.0);
    row((
        spacer().width(52.0),
        label(tr("su_title"))
            .font(Font::Headline)
            .weight(FontWeight::Heavy)
            .color(TEXT)
            .align(TextAlign::Center)
            .grow_w(),
        pause,
    ))
    .align(VAlign::Center)
    .width(BOARD)
}

/// Difficulty • time (or "Game Over" once the puzzle is revealed), as two pills.
fn status_bar(ui: Rc<Ui>) -> impl Piece {
    fn pill(
        title: day_fluent::LocalizedText,
        value: impl Fn() -> String + 'static,
        tint: impl Fn() -> Color + 'static,
        id: &'static str,
    ) -> impl Piece {
        column((
            label(title).font(Font::Caption2).color(TEXT_DIM),
            label(value)
                .font(Font::Callout)
                .bold()
                .tabular()
                .color(tint)
                .id(id)
                // Room for "00:00" from the first layout, so a ticking value never truncates.
                .min_width(72.0),
        ))
        .spacing(2.0)
        .align(HAlign::Center)
        .padding(Insets {
            top: 6.0,
            leading: 12.0,
            bottom: 6.0,
            trailing: 12.0,
        })
        .background(Color::rgba(1.0, 1.0, 1.0, 0.05))
        .corner_radius(10.0)
        .grow_w()
    }
    let (u1, u2, u3, u4) = (ui.clone(), ui.clone(), ui.clone(), ui);
    let difficulty = pill(
        tr("su_difficulty"),
        move || {
            u1.board.track();
            difficulty_label(u1.game.borrow().difficulty).format()
        },
        move || {
            u2.board.track();
            accent(u2.game.borrow().difficulty)
        },
        "su-difficulty",
    );
    let time = pill(
        tr("su_time"),
        move || {
            u3.board.track();
            u3.clock.track();
            let g = u3.game.borrow();
            if g.given_up {
                tr("gk_game_over").format()
            } else {
                fmt_time(g.elapsed as u64)
            }
        },
        move || {
            u4.board.track();
            if u4.game.borrow().given_up {
                OVER_TINT
            } else {
                TIME_TINT
            }
        },
        "su-time",
    );
    row((difficulty, time)).spacing(8.0).width(BOARD)
}

/// The 9×9 board: Day's eager grid of interactive cell canvases, with the pause cover over it.
fn board_grid(ui: Rc<Ui>) -> impl Piece {
    let mut rows = Vec::new();
    for r in 0..9usize {
        let mut cells = Vec::new();
        for c in 0..9usize {
            cells.push(cell_piece(ui.clone(), r, c));
        }
        rows.push(grid_row(PieceVec(cells)).any());
    }
    // The board's fill and rim sit UNDER the cells: a canvas above them would take every
    // press on the web, where the topmost element gets the pointer (native toolkits let a
    // handler-less canvas fall through). The cells leave the 4pt padding band for the rim.
    let rim = canvas(|d, sz| {
        d.fill(
            Shape::RoundedRect(Rect::new(0.0, 0.0, sz.width, sz.height), 10.0),
            BOARD_BG,
        );
        d.stroke(
            Shape::RoundedRect(Rect::new(1.0, 1.0, sz.width - 2.0, sz.height - 2.0), 10.0),
            BOARD_RIM,
            2.0,
        );
    })
    .on_key(keys(&ui))
    .frame(BOARD, BOARD);
    let pause_cover = {
        let u = ui.clone();
        when(
            move || {
                u.board.track();
                let g = u.game.borrow();
                g.paused && !g.locked()
            },
            || {
                canvas(|d, sz| {
                    d.fill(
                        Shape::RoundedRect(Rect::new(0.0, 0.0, sz.width, sz.height), 10.0),
                        Color::rgba(0.0, 0.0, 0.0, 0.82),
                    );
                    let c = Point::new(sz.width / 2.0, sz.height / 2.0 - 24.0);
                    draw_glyph(d, Glyph::Pause, c, 54.0, Color::rgba(1.0, 1.0, 1.0, 0.75));
                    d.text(
                        &tr("gk_paused").format(),
                        Point::new(sz.width / 2.0, sz.height / 2.0 + 34.0),
                        TextStyle {
                            size: 22.0,
                            color: Color::rgba(1.0, 1.0, 1.0, 0.75),
                            anchor: TextAnchor::CENTERED,
                            font: canvas_font(FontWeight::Heavy),
                        },
                    );
                })
                .frame(BOARD, BOARD)
                .id("su-pause-cover")
            },
        )
    };
    zstack((
        rim,
        grid(PieceVec(rows)).padding(BOARD_PAD).id("su-board"),
        pause_cover,
    ))
    .frame(BOARD, BOARD)
}

fn cell_piece(ui: Rc<Ui>, r: usize, c: usize) -> AnyPiece {
    let i = idx(r, c);
    let (draw_ui, tap_ui, key_ui) = (ui.clone(), ui.clone(), ui);
    canvas(move |d, sz| {
        draw_ui.board.track();
        let g = draw_ui.game.borrow();
        draw_cell(
            d,
            sz,
            r,
            c,
            g.values[i],
            g.notes[i],
            cell_background(&g, i),
            cell_ink(&g, i),
            g.original[i],
            g.provisional[i],
        );
    })
    .on_tap(move || {
        let mut g = tap_ui.game.borrow_mut();
        if g.busy() {
            return;
        }
        g.selected = Some(i);
        drop(g);
        tap_ui.board.notify();
        tap_ui.cue(&cues::TICK);
    })
    .on_key(move |k| key_ui.key(k))
    .a11y(move |a| {
        a.label(
            tr("su_cell_a11y")
                .arg("row", (r + 1) as f64)
                .arg("col", (c + 1) as f64)
                .format(),
        )
    })
    .id(format!("su-cell-{i}"))
    .frame(CELL, CELL)
    .any()
}

/// Notes and Hint on the left, the 3×3 number pad in the middle, Undo/Redo and
/// Checkpoint/Commit/Revert on the right.
fn control_pad(ui: Rc<Ui>) -> impl Piece {
    let notes = {
        let (u1, u2, u3, tu) = (ui.clone(), ui.clone(), ui.clone(), ui.clone());
        action_button(
            Glyph::Pencil,
            move || {
                if u1.game.borrow().notes_mode {
                    tr("su_notes_on").format()
                } else {
                    tr("su_notes").format()
                }
            },
            move || u2.game.borrow().notes_mode,
            move || u3.game.borrow().busy(),
            move || {
                tu.edit(|g| {
                    if !g.busy() {
                        g.notes_mode = !g.notes_mode;
                    }
                });
                tu.cue(&NOTES);
            },
            ui.clone(),
            "su-notes",
        )
    };
    let hint = {
        let (u1, u2, tu) = (ui.clone(), ui.clone(), ui.clone());
        action_button(
            Glyph::Bulb,
            move || {
                let g = u1.game.borrow();
                if g.difficulty.unlimited_hints() {
                    tr("su_hint_unlimited").format()
                } else if !g.difficulty.hints_enabled() {
                    tr("su_hint").format()
                } else {
                    tr("su_hint_n").arg("n", g.hints_remaining as f64).format()
                }
            },
            || false,
            move || !u2.game.borrow().can_hint(),
            move || {
                tu.edit(|g| {
                    g.hint();
                });
                tu.cue(&HINT);
            },
            ui.clone(),
            "su-hint",
        )
    };
    let undo = {
        let (cu, au, su) = (ui.clone(), ui.clone(), ui.clone());
        when(
            move || {
                cu.board.track();
                cu.game.borrow().can_redo()
            },
            move || {
                let (u1, u2, u3, u4) = (su.clone(), su.clone(), su.clone(), su.clone());
                split_button(
                    Glyph::Undo,
                    tr("su_undo"),
                    move || !u1.game.borrow().can_undo(),
                    move || {
                        u2.edit(|g| g.undo());
                        u2.cue(&UNDO);
                    },
                    "su-undo",
                    Glyph::Redo,
                    tr("su_redo"),
                    move || !u3.game.borrow().can_redo(),
                    move || {
                        u4.edit(|g| g.redo());
                        u4.cue(&REDO);
                    },
                    "su-redo",
                    su.clone(),
                )
            },
        )
        .otherwise(move || {
            let (u1, u2) = (au.clone(), au.clone());
            action_button(
                Glyph::Undo,
                || tr("su_undo").format(),
                || false,
                move || !u1.game.borrow().can_undo(),
                move || {
                    u2.edit(|g| g.undo());
                    u2.cue(&UNDO);
                },
                au.clone(),
                "su-undo",
            )
        })
    };
    let checkpoint = {
        let (cu, au, su) = (ui.clone(), ui.clone(), ui.clone());
        when(
            move || {
                cu.board.track();
                cu.game.borrow().checkpoint_active
            },
            move || {
                let (u1, u2, u3, u4) = (su.clone(), su.clone(), su.clone(), su.clone());
                split_button(
                    Glyph::Check,
                    tr("su_commit"),
                    move || u1.game.borrow().busy(),
                    move || {
                        u2.edit(|g| g.commit_checkpoint());
                        u2.cue(&cues::SUCCESS);
                    },
                    "su-commit",
                    Glyph::Cross,
                    tr("su_revert"),
                    move || u3.game.borrow().busy(),
                    move || {
                        u4.edit(|g| g.revert_checkpoint());
                        u4.cue(&cues::LETDOWN);
                    },
                    "su-revert",
                    su.clone(),
                )
            },
        )
        .otherwise(move || {
            let (u1, u2) = (au.clone(), au.clone());
            action_button(
                Glyph::Flag,
                || tr("su_checkpoint").format(),
                || false,
                move || u1.game.borrow().busy(),
                move || {
                    u2.edit(|g| g.enter_checkpoint());
                    u2.cue(&CHECKPOINT);
                },
                au.clone(),
                "su-checkpoint",
            )
        })
    };
    row((
        column((notes, hint)).spacing(8.0),
        number_pad(ui),
        column((undo, checkpoint)).spacing(8.0),
    ))
    .spacing(8.0)
    .align(VAlign::Center)
}

/// The keypad: digit and remaining count on a keycap that reads raised (available), lowered
/// (the selected cell holds this digit: tapping clears it), or flat (dead).
fn number_pad(ui: Rc<Ui>) -> impl Piece {
    let mut rows = Vec::new();
    for r in 0..3u8 {
        let mut keys = Vec::new();
        for c in 1..=3u8 {
            keys.push(number_key(ui.clone(), r * 3 + c));
        }
        rows.push(row(PieceVec(keys)).spacing(KEY_GAP).any());
    }
    column(PieceVec(rows)).spacing(KEY_GAP).id("su-keypad")
}

fn number_key(ui: Rc<Ui>, digit: u8) -> AnyPiece {
    let (du, tu, ku) = (ui.clone(), ui.clone(), ui);
    canvas(move |d, sz| {
        du.board.track();
        let g = du.game.borrow();
        let remaining = 9usize.saturating_sub(g.placed_count(digit));
        let clue = g.clue_selected();
        let exhausted = g.is_exhausted(digit);
        let clears = g.clears_with(digit);
        let lowered = clears && !clue;
        let flat = clue || (exhausted && !clears) || g.busy();
        let digit_color = if clue || g.busy() {
            Color::rgba(1.0, 1.0, 1.0, 0.18)
        } else if exhausted {
            Color::rgba(1.0, 1.0, 1.0, 0.25)
        } else if g.notes_mode {
            Color::rgb(0.75, 0.85, 1.0)
        } else {
            Color::WHITE
        };
        let count_color = Color::rgba(1.0, 1.0, 1.0, if clue { 0.18 } else { 0.45 });
        let outline = Color::rgba(1.0, 1.0, 1.0, if flat { 0.18 } else { 0.42 });
        let face = if flat {
            Color::rgba(1.0, 1.0, 1.0, 0.04)
        } else if lowered {
            Color::rgba(1.0, 1.0, 1.0, 0.06)
        } else if g.notes_mode {
            Color::rgba(0.20, 0.32, 0.65, 0.55)
        } else {
            Color::rgba(1.0, 1.0, 1.0, 0.22)
        };
        let offset = if lowered {
            2.0
        } else if flat {
            0.0
        } else {
            -2.0
        };
        let (w, h) = (sz.width, sz.height);
        d.stroke(
            Shape::RoundedRect(Rect::new(1.25, 1.25, w - 2.5, h - 2.5), 10.0),
            outline,
            2.5,
        );
        d.fill(
            Shape::RoundedRect(Rect::new(4.0, 4.0 + offset, w - 8.0, h - 8.0), 6.0),
            face,
        );
        d.text(
            &digit.to_string(),
            Point::new(w / 2.0, h / 2.0 - 5.0 + offset),
            TextStyle {
                size: 26.0,
                color: digit_color,
                anchor: TextAnchor::CENTERED,
                font: canvas_font(FontWeight::Heavy),
            },
        );
        d.text(
            &remaining.to_string(),
            Point::new(w / 2.0, h - 10.0 + offset),
            TextStyle {
                size: 9.0,
                color: count_color,
                anchor: TextAnchor::CENTERED,
                font: canvas_font(FontWeight::Medium),
            },
        );
    })
    .on_tap(move || tu.enter(digit))
    .on_key(move |k| ku.key(k))
    .a11y(move |a| {
        a.label(tr("su_key_a11y").arg("n", digit as f64).format())
            .role(Role::Button)
    })
    .id(format!("su-key-{digit}"))
    .frame(KEY_W, KEY_H)
    .any()
}

/// A stacked icon + caption button.
#[allow(clippy::too_many_arguments)]
fn action_button(
    glyph: Glyph,
    title: impl Fn() -> String + 'static,
    highlighted: impl Fn() -> bool + 'static,
    disabled: impl Fn() -> bool + 'static,
    action: impl Fn() + 'static,
    ui: Rc<Ui>,
    id: &'static str,
) -> AnyPiece {
    let a11y_title = title();
    let (du, ku) = (ui.clone(), ui);
    canvas(move |d, sz| {
        du.board.track();
        let (w, h) = (sz.width, sz.height);
        let on = highlighted();
        let off = disabled();
        d.fill(
            Shape::RoundedRect(Rect::new(0.0, 0.0, w, h), 10.0),
            if on {
                KEY_BLUE.with_alpha(0.6)
            } else {
                Color::rgba(1.0, 1.0, 1.0, 0.06)
            },
        );
        let ink = if on {
            Color::WHITE
        } else {
            Color::rgba(1.0, 1.0, 1.0, if off { 0.35 } else { 0.80 })
        };
        draw_glyph(d, glyph, Point::new(w / 2.0, h / 2.0 - 9.0), 18.0, ink);
        d.text(
            &title(),
            Point::new(w / 2.0, h / 2.0 + 12.0),
            TextStyle {
                size: 10.0,
                color: ink,
                anchor: TextAnchor::CENTERED,
                font: canvas_font(FontWeight::Semibold),
            },
        );
    })
    .on_tap(action)
    .on_key(move |k| ku.key(k))
    .a11y(move |a| a.label(a11y_title.clone()).role(Role::Button))
    .id(id)
    .frame(ACTION_W, ACTION_H)
    .any()
}

/// Two half-height buttons sharing one action button's footprint, split by a hairline.
#[allow(clippy::too_many_arguments)]
fn split_button(
    top_glyph: Glyph,
    top_title: day_fluent::LocalizedText,
    top_disabled: impl Fn() -> bool + 'static,
    top_action: impl Fn() + 'static,
    top_id: &'static str,
    bottom_glyph: Glyph,
    bottom_title: day_fluent::LocalizedText,
    bottom_disabled: impl Fn() -> bool + 'static,
    bottom_action: impl Fn() + 'static,
    bottom_id: &'static str,
    ui: Rc<Ui>,
) -> AnyPiece {
    let half = |glyph: Glyph,
                title: day_fluent::LocalizedText,
                disabled: Box<dyn Fn() -> bool>,
                action: Box<dyn Fn()>,
                id: &'static str,
                top: bool| {
        let (du, ku) = (ui.clone(), ui.clone());
        let a11y_title = title.format();
        canvas(move |d, sz| {
            du.board.track();
            let (w, h) = (sz.width, sz.height);
            // The shared rounded background, clipped to this half.
            let bg = Rect::new(0.0, if top { 0.0 } else { -h }, w, 2.0 * h);
            d.clipped(Shape::Rect(Rect::new(0.0, 0.0, w, h)), |d| {
                d.fill(
                    Shape::RoundedRect(bg, 10.0),
                    Color::rgba(1.0, 1.0, 1.0, 0.06),
                );
            });
            if !top {
                d.fill(
                    Shape::Rect(Rect::new(0.0, 0.0, w, 1.0)),
                    Color::rgba(1.0, 1.0, 1.0, 0.18),
                );
            }
            let ink = Color::rgba(1.0, 1.0, 1.0, if disabled() { 0.35 } else { 0.80 });
            draw_glyph(d, glyph, Point::new(w * 0.2, h / 2.0), 12.0, ink);
            d.text(
                &title.format(),
                Point::new(w * 0.33, h / 2.0),
                TextStyle {
                    size: 10.0,
                    color: ink,
                    anchor: TextAnchor {
                        h: TextAlign::Leading,
                        v: TextVAlign::Middle,
                    },
                    font: canvas_font(FontWeight::Semibold),
                },
            );
        })
        .on_tap(action)
        .on_key(move |k| ku.key(k))
        .a11y(move |a| a.label(a11y_title.clone()).role(Role::Button))
        .id(id)
        .frame(ACTION_W, ACTION_H / 2.0)
    };
    column((
        half(
            top_glyph,
            top_title,
            Box::new(top_disabled),
            Box::new(top_action),
            top_id,
            true,
        ),
        half(
            bottom_glyph,
            bottom_title,
            Box::new(bottom_disabled),
            Box::new(bottom_action),
            bottom_id,
            false,
        ),
    ))
    .spacing(0.0)
    .any()
}

// ---------------------------------------------------------------------------
// Overlays
// ---------------------------------------------------------------------------

/// The scrim and card of whichever surface is up.
fn overlays(ui: Rc<Ui>) -> impl Piece {
    let scrim = {
        let u = ui.clone();
        when(
            move || u.overlay.get() != Overlay::None,
            || {
                canvas(|d, sz| {
                    d.fill(Shape::Rect(Rect::new(0.0, 0.0, sz.width, sz.height)), SCRIM);
                })
                // Absorbs taps so the board underneath never hears them.
                .on_tap(|| {})
                .grow()
            },
        )
    };
    let (p, s, d, t, i) = (ui.clone(), ui.clone(), ui.clone(), ui.clone(), ui.clone());
    let card = move |kind: Overlay, build: Rc<dyn Fn() -> AnyPiece>| {
        let u = ui.clone();
        when(move || u.overlay.get() == kind, move || build())
    };
    zstack((
        scrim,
        card(Overlay::Pause, Rc::new(move || pause_menu(p.clone()))),
        card(Overlay::Solved, Rc::new(move || solved_card(s.clone()))),
        card(
            Overlay::Difficulty,
            Rc::new(move || difficulty_picker(d.clone())),
        ),
        card(Overlay::Settings, Rc::new(move || settings_card(t.clone()))),
        card(
            Overlay::Instructions,
            Rc::new(move || instructions_card(i.clone())),
        ),
    ))
}

fn card_frame(content: impl Piece) -> AnyPiece {
    content
        .padding(24.0)
        .background(CARD)
        .corner_radius(20.0)
        .max_width(380.0)
        .any()
}

/// A menu button: filled in `tint`, one fixed width so the stack lines up.
fn menu_button(
    title: day_fluent::LocalizedText,
    tint: Color,
    id: &'static str,
    action: impl Fn() + 'static,
) -> AnyPiece {
    button(title)
        .prominent()
        .tint(tint)
        .action(action)
        .id(id)
        .width(MENU_W)
        .any()
}

fn pause_menu(ui: Rc<Ui>) -> AnyPiece {
    let live = !ui.game.borrow().locked();
    let resume = {
        let u = ui.clone();
        when(
            move || live,
            move || {
                let u = u.clone();
                menu_button(tr("gk_resume"), GREEN, "su-resume", move || {
                    u.show(Overlay::None);
                })
            },
        )
    };
    let give_up = {
        let u = ui.clone();
        when(
            move || live,
            move || {
                let u = u.clone();
                menu_button(tr("su_give_up"), AMBER, "su-give-up", move || {
                    let u = u.clone();
                    day_core::task(async move {
                        let sure = Alert::new(tr("su_give_up_title"))
                            .message(tr("su_give_up_message"))
                            .destructive(tr("su_give_up_confirm"), true)
                            .cancel(tr("gk_cancel"))
                            .present()
                            .await;
                        if sure == Some(true) {
                            u.edit(|g| g.give_up());
                            u.show(Overlay::None);
                            u.cue(&cues::OVER_PUZZLE);
                        }
                    });
                })
            },
        )
    };
    let (u1, u2, u3) = (ui.clone(), ui.clone(), ui.clone());
    card_frame(
        column((
            label(tr("gk_paused"))
                .font(Font::LargeTitle)
                .weight(FontWeight::Black)
                .color(Color::WHITE),
            resume,
            menu_button(tr("gk_new_game"), KEY_BLUE, "su-new-game", move || {
                u1.push(Overlay::Difficulty)
            }),
            menu_button(tr("gk_settings"), SLATE, "su-settings", move || {
                u2.push(Overlay::Settings)
            }),
            menu_button(
                tr("gk_instructions"),
                INDIGO,
                "su-instructions",
                move || u3.push(Overlay::Instructions),
            ),
            give_up,
            menu_button(tr("gk_quit"), RED, "su-quit", || {
                nav_back();
            }),
        ))
        .spacing(14.0)
        .align(HAlign::Center),
    )
    .id("su-pause-menu")
    .any()
}

fn solved_card(ui: Rc<Ui>) -> AnyPiece {
    let (elapsed, best, new_best) = {
        let g = ui.game.borrow();
        (
            g.elapsed as u64,
            g.records.best[g.difficulty.index()],
            g.new_best,
        )
    };
    let record = if new_best {
        label(tr("su_new_best"))
            .font(Font::Title3)
            .bold()
            .color(GOLD)
            .any()
    } else if best > 0 {
        label(tr("su_best").arg("time", fmt_time(best)))
            .font(Font::Subheadline)
            .color(TEXT_DIM)
            .any()
    } else {
        spacer().height(0.0).any()
    };
    let u = ui;
    card_frame(
        column((
            label(tr("su_stars")).font(Font::Title),
            label(tr("su_solved_title"))
                .font(Font::LargeTitle)
                .weight(FontWeight::Black)
                .color(GOLD)
                .align(TextAlign::Center),
            column((
                label(tr("su_time")).font(Font::Caption).color(TEXT_DIM),
                label(fmt_time(elapsed))
                    .font(Font::Title3)
                    .bold()
                    .tabular()
                    .color(INK_USER)
                    .id("su-solved-time"),
            ))
            .spacing(2.0)
            .align(HAlign::Center),
            record,
            menu_button(tr("gk_play_again"), KEY_BLUE, "su-play-again", move || {
                u.push(Overlay::Difficulty)
            }),
            menu_button(tr("gk_quit"), RED, "su-quit", || {
                nav_back();
            }),
        ))
        .spacing(14.0)
        .align(HAlign::Center),
    )
    .id("su-solved")
    .any()
}

fn difficulty_picker(ui: Rc<Ui>) -> AnyPiece {
    let current = ui.game.borrow().difficulty;
    let mut cards = Vec::new();
    for d in DIFFICULTIES {
        let u = ui.clone();
        let tint = accent(d);
        let check = when(
            move || d == current,
            move || {
                canvas(move |dr, sz| {
                    draw_glyph(
                        dr,
                        Glyph::Check,
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
                    label(difficulty_label(d))
                        .font(Font::Title3)
                        .bold()
                        .color(Color::WHITE),
                    label(difficulty_detail(d))
                        .font(Font::Caption)
                        .color(TEXT_DIM),
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
            .a11y(move |a| a.label(difficulty_label(d).format()).role(Role::Button))
            .id(difficulty_id(d))
            .width(300.0)
            .any(),
        );
    }
    let u = ui;
    card_frame(
        column((
            label(tr("su_choose_difficulty"))
                .font(Font::Title2)
                .bold()
                .color(Color::WHITE),
            column(PieceVec(cards)).spacing(12.0),
            button(tr("gk_cancel"))
                .action(move || u.pop())
                .id("su-cancel"),
        ))
        .spacing(16.0)
        .align(HAlign::Center),
    )
    .id("su-difficulty-picker")
    .any()
}

fn settings_card(ui: Rc<Ui>) -> AnyPiece {
    let heading = |t: day_fluent::LocalizedText| {
        label(t)
            .font(Font::Caption)
            .weight(FontWeight::Semibold)
            .color(TEXT_DIM)
    };
    let setting_row = |t: day_fluent::LocalizedText, control: AnyPiece| {
        row((label(t).color(TEXT).grow_w(), control))
            .align(VAlign::Center)
            .width(300.0)
    };
    let mut record_rows = Vec::new();
    for d in DIFFICULTIES {
        let u = ui.clone();
        record_rows.push(
            setting_row(
                difficulty_label(d),
                label(move || {
                    u.board.track();
                    match u.game.borrow().records.best[d.index()] {
                        0 => "—".to_string(),
                        b => fmt_time(b),
                    }
                })
                .tabular()
                .color(TEXT_DIM)
                .any(),
            )
            .any(),
        );
    }
    let solved = {
        let u = ui.clone();
        setting_row(
            tr("su_puzzles_solved"),
            label(move || {
                u.board.track();
                u.game.borrow().records.solved.to_string()
            })
            .tabular()
            .color(TEXT_DIM)
            .id("su-puzzles-solved")
            .any(),
        )
    };
    let reset = {
        let u = ui.clone();
        button(tr("su_reset_records"))
            .tint(RED)
            .action(move || {
                let u = u.clone();
                day_core::task(async move {
                    let sure = Alert::new(tr("su_reset_title"))
                        .message(tr("su_reset_message"))
                        .destructive(tr("gk_reset_confirm"), true)
                        .cancel(tr("gk_cancel"))
                        .present()
                        .await;
                    if sure == Some(true) {
                        u.game.borrow_mut().records = Records::default();
                        gamekit::clear(RECORDS_KEY);
                        u.board.notify();
                    }
                });
            })
            .id("su-reset-records")
    };
    let difficulty_names: Vec<String> = DIFFICULTIES
        .iter()
        .map(|&d| difficulty_label(d).format())
        .collect();
    let done = ui.clone();
    card_frame(
        scroll(
            column((
                label(tr("gk_settings"))
                    .font(Font::Title2)
                    .bold()
                    .color(Color::WHITE),
                heading(tr("nav_sudoku")),
                setting_row(tr("gk_sounds"), toggle(ui.sounds).id("su-sounds").any()),
                setting_row(
                    tr("gk_vibrations"),
                    toggle(ui.vibrations).id("su-vibrations").any(),
                ),
                setting_row(
                    tr("su_default_difficulty"),
                    picker(difficulty_names, ui.default_difficulty)
                        .menu()
                        .id("su-default-difficulty")
                        .any(),
                ),
                heading(tr("su_records")),
                column(PieceVec(record_rows)).spacing(8.0),
                solved,
                heading(tr("gk_data")),
                reset,
                button(tr("gk_done"))
                    .prominent()
                    .action(move || done.pop())
                    .id("su-done"),
            ))
            .spacing(12.0)
            .align(HAlign::Center),
        )
        .height(440.0),
    )
    .id("su-settings-card")
    .any()
}

/// The how-to-play sheet: headings and bullets as labels, inline markdown for the emphasis.
fn instructions_card(ui: Rc<Ui>) -> AnyPiece {
    let heading = |t: day_fluent::LocalizedText| {
        label(t)
            .font(Font::Headline)
            .color(Color::WHITE)
            .align(TextAlign::Leading)
    };
    let para = |t: day_fluent::LocalizedText| {
        label(t)
            .font(Font::Body)
            .color(TEXT)
            .markdown()
            .align(TextAlign::Leading)
    };
    let done = ui;
    let body = column((
        para(tr("su_help_intro")),
        heading(tr("su_help_play")),
        para(tr("su_help_play_1")),
        para(tr("su_help_play_2")),
        para(tr("su_help_play_3")),
        para(tr("su_help_play_4")),
        para(tr("su_help_play_5")),
        heading(tr("su_help_checkpoint")),
        para(tr("su_help_checkpoint_1")),
        para(tr("su_help_checkpoint_2")),
    ))
    .spacing(10.0)
    .align(HAlign::Leading);
    let tail = column((
        heading(tr("su_help_undo")),
        para(tr("su_help_undo_1")),
        para(tr("su_help_undo_2")),
        heading(tr("su_help_win")),
        para(tr("su_help_win_1")),
        para(tr("su_help_win_2")),
        para(tr("su_help_win_3")),
        para(tr("su_help_win_4")),
    ))
    .spacing(10.0)
    .align(HAlign::Leading);
    card_frame(
        scroll(
            column((
                label(tr("nav_sudoku"))
                    .font(Font::Title2)
                    .bold()
                    .color(Color::WHITE),
                body,
                tail,
                button(tr("gk_done"))
                    .prominent()
                    .action(move || done.pop())
                    .id("su-help-done"),
            ))
            .spacing(10.0)
            .align(HAlign::Leading)
            .width(300.0),
        )
        .height(440.0),
    )
    .id("su-instructions-card")
    .any()
}
