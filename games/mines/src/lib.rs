//! Mines is the classic sweeper on one immediate-mode canvas (docs/canvas.md), stepped on Day's
//! frame clock: squares pop open in rings out from the tap, flags plant with a wobble, a mine ends
//! the game with a shake and a burst of sparks, and a swept board plants the flags it never had to.
//! The first tap is always safe: the mines are laid around it (model.rs).
//!
//! Hold a square to flag it without lifting your finger, or turn on Flag Mode and tap; tap a number
//! whose flags are all placed and the rest of its neighbors open at once. On a keyboard the arrows
//! move a pointer, Space or Return uncovers, and F flags. The board turns with the window (tall on
//! a phone, wide on a desktop) so its squares stay big enough to hit at any size.

use std::cell::{Cell, RefCell};
use std::f64::consts::TAU;
use std::rc::Rc;

use day_fluent::tr;
use day_geometry::Affine;
use day_part_haptics::Haptic;
use day_pieces::prelude::*;
use gamekit::chrome::cues::{self, with};
use gamekit::chrome::{self, Cue, Feedback, Help, Pattern, Sfx, sfx};

mod model;
use model::{Board, Cell as Square, DIFFICULTIES, Difficulty, Outcome, Records, Settings};

/// The prefs keys this game persists under (gamekit; bump the game key on a schema change).
const SAVE_KEY: &str = "mines.v1";
const RECORDS_KEY: &str = "mines.records";
const SETTINGS_KEY: &str = "mines.settings";

/// The game's cover surface color (edge-to-edge behind the safe area).
pub const SURFACE: Color = Color::hex(0x10_14_22);
const BOARD_BG: Color = Color::hex(0x17_1C_2E);
/// A covered square: a lit top edge over the face, so the board reads as buttons to press.
const FACE: Color = Color::hex(0x2B_34_4F);
const FACE_TOP: Color = Color::hex(0x38_43_63);
const OPEN: Color = Color::hex(0x1A_20_33);
const OPEN_EDGE: Color = Color::rgba(1.0, 1.0, 1.0, 0.05);
const FLAG_RED: Color = Color::rgb(0.93, 0.31, 0.34);
const FLAG_POLE: Color = Color::rgba(1.0, 1.0, 1.0, 0.75);
const MINE_DARK: Color = Color::rgb(0.04, 0.05, 0.09);
const BOOM_RED: Color = Color::rgb(0.82, 0.20, 0.24);
const CURSOR: Color = Color::rgba(0.55, 0.80, 1.0, 0.95);
/// One color per number, 1 through 8, tuned for the dark face.
const NUMBERS: [Color; 8] = [
    Color::hex(0x5B_A8_FF),
    Color::hex(0x4A_DE_80),
    Color::hex(0xFF_7B_6B),
    Color::hex(0xC0_84_FC),
    Color::hex(0xFB_BF_24),
    Color::hex(0x22_D3_EE),
    Color::hex(0xF1_F5_F9),
    Color::hex(0x94_A3_B8),
];

/// The biggest a square gets, so a desktop window shows a board rather than a wall of tiles.
const MAX_CELL: f64 = 54.0;
const PAD: f64 = 8.0;
/// A press held this long flags without lifting the finger.
const HOLD: f64 = 0.35;
/// How far a press may slide and still count as a press rather than a scroll.
const SLOP: f64 = 12.0;
/// A square pops open over this long, each one waiting [`RIPPLE`] per step out from the tap.
const POP: f64 = 0.18;
const RIPPLE: f64 = 0.016;
/// How long the explosion (or the win) holds the board before its card.
const BOOM_HOLD: f64 = 1.7;
const WIN_HOLD: f64 = 1.3;
/// The board shakes for this long after a mine goes off.
const SHAKE: f64 = 0.45;

// Sounds, each with the haptic it plays beside (gamekit::chrome::Cue).
const CHORD_BEAT: Pattern = &[(0, Haptic::Heavy), (60, Haptic::Light)];
static REVEAL: Cue = with("sounds/mines/reveal.wav", cues::TICK_BEAT);
static FLAG: Cue = with("sounds/mines/flag.wav", cues::MEDIUM_BEAT);
static UNFLAG: Cue = with("sounds/mines/unflag.wav", cues::LIGHT_BEAT);
static CHORD: Cue = with("sounds/mines/chord.wav", CHORD_BEAT);
static BOOM: Cue = with("sounds/mines/boom.wav", chrome::GAME_OVER);
static WIN: Cue = with("sounds/mines/win.wav", chrome::BIG_CELEBRATE);
/// A cascade's extra ticks, so opening half the board sounds like it.
const RIPPLE_SFX: Sfx = sfx("sounds/mines/reveal.wav");

/// Every clip this game plays besides the shared ones (gamekit preloads both).
pub const SOUNDS: &[Sfx] = &[
    sfx("sounds/mines/reveal.wav"),
    sfx("sounds/mines/flag.wav"),
    sfx("sounds/mines/unflag.wav"),
    sfx("sounds/mines/chord.wav"),
    sfx("sounds/mines/boom.wav"),
    sfx("sounds/mines/win.wav"),
];

fn fmt_time(secs: f64) -> String {
    let s = secs.floor().max(0.0) as u32;
    format!("{}:{:02}", s / 60, s % 60)
}

fn difficulty_label(d: Difficulty) -> day_fluent::LocalizedText {
    match d {
        Difficulty::Easy => tr("mi_easy"),
        Difficulty::Medium => tr("mi_medium"),
        Difficulty::Hard => tr("mi_hard"),
    }
}

fn difficulty_id(d: Difficulty) -> &'static str {
    match d {
        Difficulty::Easy => "mi-diff-easy",
        Difficulty::Medium => "mi-diff-medium",
        Difficulty::Hard => "mi-diff-hard",
    }
}

fn difficulty_tint(d: Difficulty) -> Color {
    match d {
        Difficulty::Easy => chrome::GREEN,
        Difficulty::Medium => chrome::BLUE,
        Difficulty::Hard => chrome::RED,
    }
}

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------

/// One spark of the explosion.
struct Spark {
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    age: f64,
    life: f64,
    color: Color,
}

/// Everything animating over the board.
#[derive(Default)]
struct Fx {
    /// A square opening: its index, the wait before it pops, and its age.
    pops: Vec<(usize, f64, f64)>,
    /// A flag planting or lifting: its square and age.
    flags: Vec<(usize, f64)>,
    /// The mine that went off, and how long ago.
    boom: Option<(usize, f64)>,
    /// How long ago the board was swept.
    win: Option<f64>,
    sparks: Vec<Spark>,
}

impl Fx {
    fn clear(&mut self) {
        self.pops.clear();
        self.flags.clear();
        self.boom = None;
        self.win = None;
        self.sparks.clear();
    }

    /// How far into its pop a square is: `None` once it has settled.
    fn pop_of(&self, i: usize) -> Option<f64> {
        self.pops
            .iter()
            .find(|(c, _, _)| *c == i)
            .and_then(|(_, wait, age)| {
                let t = (age - wait) / POP;
                (t < 1.0).then_some(t.max(0.0))
            })
    }

    fn flag_of(&self, i: usize) -> Option<f64> {
        self.flags
            .iter()
            .find(|(c, _)| *c == i)
            .map(|(_, age)| (age / 0.26).min(1.0))
    }

    fn step(&mut self, dt: f64) {
        for p in &mut self.pops {
            p.2 += dt;
        }
        self.pops.retain(|(_, wait, age)| *age < wait + POP);
        for f in &mut self.flags {
            f.1 += dt;
        }
        self.flags.retain(|(_, age)| *age < 0.26);
        if let Some((_, age)) = &mut self.boom {
            *age += dt;
        }
        if let Some(age) = &mut self.win {
            *age += dt;
        }
        for s in &mut self.sparks {
            s.age += dt;
            s.x += s.vx * dt;
            s.y += s.vy * dt;
            s.vy += 900.0 * dt;
        }
        self.sparks.retain(|s| s.age < s.life);
    }
}

/// A finger or pointer on the board: the square it went down on, how long it has been there, and
/// whether it has already done something (a hold, a release or a tap that acted) or wandered off
/// (a scroll).
struct Press {
    cell: usize,
    age: f64,
    moved: bool,
    handled: bool,
}

/// Claim a press for the move its release makes, at the end of its drag: only a press that
/// neither slid nor already acted. The press stays behind, marked, for [`claim_at_tap`].
///
/// A press that never moves reaches the board as a tap, as a zero-length drag, or as both, in
/// either order (docs/canvas.md "Interaction"): Android reports the drag's end and then the tap.
/// A tap in Flag Mode toggles, so answering both planted a flag and lifted it in the same touch.
fn claim_at_release(press: &mut Option<Press>) -> bool {
    match press.as_mut() {
        Some(p) if !p.handled && !p.moved => {
            p.handled = true;
            true
        }
        _ => false,
    }
}

/// Claim a press for a tap report. With no press (a backend that reports only taps) the tap
/// acts; a press its release or a hold already acted on is spent, and cleared.
fn claim_at_tap(press: &mut Option<Press>) -> bool {
    let Some(p) = press.as_mut() else {
        return true;
    };
    if p.handled {
        *press = None;
        return false;
    }
    p.handled = true;
    true
}

#[cfg(test)]
mod press_tests {
    use super::*;

    fn down() -> Option<Press> {
        Some(Press {
            cell: 4,
            age: 0.0,
            moved: false,
            handled: false,
        })
    }

    /// Android's order: the drag ends, then the tap arrives. One move, not a flag and its undo.
    #[test]
    fn a_release_then_a_tap_is_one_move() {
        let mut press = down();
        assert!(claim_at_release(&mut press));
        assert!(!claim_at_tap(&mut press));
        assert!(press.is_none());
    }

    #[test]
    fn a_tap_then_a_release_is_one_move() {
        let mut press = down();
        assert!(claim_at_tap(&mut press));
        assert!(!claim_at_release(&mut press));
    }

    #[test]
    fn a_tap_or_a_release_alone_still_moves() {
        assert!(claim_at_tap(&mut None));
        assert!(claim_at_release(&mut down()));
    }

    /// The frame clock marks a held press when it flags; neither report may act on it again.
    #[test]
    fn a_hold_leaves_nothing_for_the_release_or_the_tap() {
        let mut press = down();
        if let Some(p) = press.as_mut() {
            p.handled = true;
        }
        assert!(!claim_at_release(&mut press));
        assert!(!claim_at_tap(&mut press));
    }

    /// A slide is no tap at its release, but a platform that still calls it a tap is believed.
    #[test]
    fn a_slide_acts_only_if_the_platform_reports_a_tap() {
        let mut press = down();
        if let Some(p) = press.as_mut() {
            p.moved = true;
        }
        assert!(!claim_at_release(&mut press));
        assert!(claim_at_tap(&mut press));
    }
}

/// Where the board sits in the canvas: square size and the board's top-left, centered both ways.
#[derive(Clone, Copy, Default)]
struct Lay {
    cell: f64,
    ox: f64,
    oy: f64,
}

fn lay(board: &Board, sz: Size) -> Lay {
    let cell = ((sz.width - 2.0 * PAD) / board.cols as f64)
        .min((sz.height - 2.0 * PAD) / board.rows as f64)
        .clamp(6.0, MAX_CELL);
    Lay {
        cell,
        ox: (sz.width - cell * board.cols as f64) / 2.0,
        oy: (sz.height - cell * board.rows as f64) / 2.0,
    }
}

impl Lay {
    fn rect(&self, board: &Board, i: usize) -> Rect {
        let (c, r) = board.col_row(i);
        Rect::new(
            self.ox + c as f64 * self.cell,
            self.oy + r as f64 * self.cell,
            self.cell,
            self.cell,
        )
    }

    fn center(&self, board: &Board, i: usize) -> Point {
        let r = self.rect(board, i);
        Point::new(
            r.origin.x + r.size.width / 2.0,
            r.origin.y + r.size.height / 2.0,
        )
    }

    fn hit(&self, board: &Board, p: Point) -> Option<usize> {
        let c = ((p.x - self.ox) / self.cell).floor();
        let r = ((p.y - self.oy) / self.cell).floor();
        if c < 0.0 || r < 0.0 || c >= board.cols as f64 || r >= board.rows as f64 {
            return None;
        }
        Some(board.at(c as usize, r as usize))
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Overlay {
    None,
    Pause,
    Picker,
    Won,
    Lost,
    Settings,
    Instructions,
}

struct Ui {
    board: RefCell<Board>,
    difficulty: Cell<Difficulty>,
    records: RefCell<Records>,
    fx: RefCell<Fx>,
    press: RefCell<Option<Press>>,
    /// Where the keyboard is pointing.
    cursor: Cell<Option<usize>>,
    /// The canvas's last size, which decides the next board's shape.
    field: Cell<Size>,
    lay: Cell<Lay>,
    flag_mode: Signal<bool>,
    overlay: Signal<Overlay>,
    /// Where Done in Settings or the rules returns to.
    return_to: Cell<Overlay>,
    /// The board layer: every animated frame.
    repaint: Trigger,
    /// The HUD: the clock's whole seconds, the flag count, and the buttons.
    hud: Trigger,
    seen_second: Cell<u32>,
    sounds: Signal<bool>,
    vibrations: Signal<bool>,
    /// This game has been counted in the records.
    counted: Cell<bool>,
    new_best: Cell<bool>,
    focus: Signal<bool>,
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

    fn show(&self, o: Overlay) {
        self.overlay.set(o);
        self.repaint.notify();
        self.hud.notify();
        if o == Overlay::None {
            self.focus.set(true);
        }
    }

    fn push(&self, o: Overlay) {
        self.return_to.set(self.overlay.get_untracked());
        self.show(o);
    }

    fn pop(&self) {
        let back = self.return_to.replace(Overlay::None);
        self.show(back);
    }

    fn pause(&self) {
        if self.overlay.get_untracked() == Overlay::None && !self.board.borrow().over() {
            self.show(Overlay::Pause);
            self.cue(&cues::SELECT);
        }
    }

    /// Deal a new board at `d`, shaped to the window it will be played in.
    fn new_game(&self, d: Difficulty) {
        let field = self.field.get();
        let landscape = field.width > field.height * 1.05;
        let (cols, rows) = d.shape(landscape);
        *self.board.borrow_mut() = Board::new(cols, rows, d.mines(), gamekit::seed());
        self.difficulty.set(d);
        self.fx.borrow_mut().clear();
        *self.press.borrow_mut() = None;
        self.cursor.set(None);
        self.counted.set(false);
        self.new_best.set(false);
        gamekit::clear(SAVE_KEY);
        self.show(Overlay::None);
        self.cue(&cues::START);
    }

    /// A tap: uncover, or plant a flag when Flag Mode is on.
    fn tap(&self, i: usize) {
        let flag = self.flag_mode.get_untracked();
        let out = {
            let mut b = self.board.borrow_mut();
            if flag { b.flag(i) } else { b.reveal(i) }
        };
        self.apply(i, out);
    }

    /// A press held: the other action, so a hold flags while a tap uncovers (and the other way
    /// round in Flag Mode).
    fn hold(&self, i: usize) {
        let flag = self.flag_mode.get_untracked();
        let out = {
            let mut b = self.board.borrow_mut();
            if flag { b.reveal(i) } else { b.flag(i) }
        };
        self.apply(i, out);
    }

    /// Everything an [`Outcome`] earns: the sounds, the animations, and the card it ends on.
    fn apply(&self, at: usize, out: Outcome) {
        if !out.did_something() {
            // A number tapped without its flags placed: a nudge, not silence.
            let numbered = {
                let b = self.board.borrow();
                b.state[at] == Square::Revealed && b.near[at] > 0
            };
            if numbered {
                self.cue(&cues::WARNING);
            }
            return;
        }
        {
            let board = self.board.borrow();
            let mut fx = self.fx.borrow_mut();
            if let Some(i) = out.flagged.or(out.unflagged) {
                fx.flags.push((i, 0.0));
            }
            // The cascade pops in rings out from the tap.
            let from = board.col_row(at);
            for &i in &out.revealed {
                let (c, r) = board.col_row(i);
                let step = (c as f64 - from.0 as f64)
                    .abs()
                    .max((r as f64 - from.1 as f64).abs());
                fx.pops.push((i, step * RIPPLE, 0.0));
            }
            if let Some(i) = out.boom {
                fx.boom = Some((i, 0.0));
                let at = self.lay.get().center(&board, i);
                let mut seed = i as u64 * 2654435761 + 12345;
                for _ in 0..26 {
                    seed = seed
                        .wrapping_mul(6364136223846793005)
                        .wrapping_add(1442695040888963407);
                    let a = (seed >> 33) as f64 / (1u64 << 31) as f64 * TAU;
                    let speed = 120.0 + ((seed >> 11) % 260) as f64;
                    fx.sparks.push(Spark {
                        x: at.x,
                        y: at.y,
                        vx: a.cos() * speed,
                        vy: a.sin() * speed - 120.0,
                        age: 0.0,
                        life: 0.5 + ((seed >> 7) % 40) as f64 / 100.0,
                        color: if seed.is_multiple_of(3) {
                            Color::hex(0xFF_C4_4D)
                        } else {
                            FLAG_RED
                        },
                    });
                }
            }
            if out.won {
                fx.win = Some(0.0);
            }
        }
        if out.flagged.is_some() {
            self.cue(&FLAG);
        } else if out.unflagged.is_some() {
            self.cue(&UNFLAG);
        }
        if out.boom.is_some() {
            self.cue(&BOOM);
            self.record(false);
        } else if out.won {
            self.cue(&WIN);
            self.record(true);
        } else if !out.revealed.is_empty() {
            self.cue(if out.chorded { &CHORD } else { &REVEAL });
            // A big cascade keeps ticking as it runs, quieter each step.
            let on = self.sounds.get_untracked();
            for (n, delay) in [(1usize, 80u32), (2, 150)] {
                if out.revealed.len() > n * 4 {
                    chrome::sound_after(on, &RIPPLE_SFX, 0.55 / n as f32, delay);
                }
            }
        }
        self.repaint.notify();
        self.hud.notify();
    }

    /// Count a finished game once, and remember whether it set a best time.
    fn record(&self, won: bool) {
        if self.counted.replace(true) {
            return;
        }
        let secs = self.board.borrow().elapsed;
        let best = self
            .records
            .borrow_mut()
            .record(self.difficulty.get(), won, secs);
        self.new_best.set(best);
        gamekit::save(RECORDS_KEY, &*self.records.borrow());
        gamekit::clear(SAVE_KEY);
    }

    fn key(&self, key: &str) {
        if self.overlay.get_untracked() != Overlay::None {
            return;
        }
        let (cols, len) = {
            let b = self.board.borrow();
            (b.cols as i64, b.cells() as i64)
        };
        let here = self.cursor.get().unwrap_or((len / 2) as usize);
        let step = |d: i64| ((here as i64 + d).rem_euclid(len)) as usize;
        match key {
            "ArrowLeft" => self.cursor.set(Some(step(-1))),
            "ArrowRight" => self.cursor.set(Some(step(1))),
            "ArrowUp" => self.cursor.set(Some(step(-cols))),
            "ArrowDown" => self.cursor.set(Some(step(cols))),
            " " | "Enter" => {
                self.cursor.set(Some(here));
                self.tap(here);
            }
            "f" | "F" => {
                self.cursor.set(Some(here));
                self.hold(here);
            }
            "Escape" => self.pause(),
            _ => return,
        }
        if self.cursor.get().is_none() {
            self.cursor.set(Some(here));
        }
        self.repaint.notify();
    }
}

// ---------------------------------------------------------------------------
// The page
// ---------------------------------------------------------------------------

/// The Mines screen.
pub fn mines_page() -> AnyPiece {
    let settings = gamekit::restore::<Settings>(SETTINGS_KEY).unwrap_or_default();
    let restored = gamekit::restore::<model::SaveState>(SAVE_KEY).and_then(Board::from_save);
    let (board, difficulty) = match restored {
        Some((b, d)) => (b, d),
        None => {
            let d = settings.difficulty;
            let (cols, rows) = d.shape(false);
            (Board::new(cols, rows, d.mines(), gamekit::seed()), d)
        }
    };
    let ui = Rc::new(Ui {
        board: RefCell::new(board),
        difficulty: Cell::new(difficulty),
        records: RefCell::new(gamekit::restore(RECORDS_KEY).unwrap_or_default()),
        fx: RefCell::new(Fx::default()),
        press: RefCell::new(None),
        cursor: Cell::new(None),
        field: Cell::new(Size::new(0.0, 0.0)),
        lay: Cell::new(Lay::default()),
        flag_mode: Signal::new(false),
        overlay: Signal::new(Overlay::None),
        return_to: Cell::new(Overlay::None),
        repaint: Trigger::new(),
        hud: Trigger::new(),
        seen_second: Cell::new(u32::MAX),
        sounds: Signal::new(settings.sounds),
        vibrations: Signal::new(settings.vibrations),
        counted: Cell::new(false),
        new_best: Cell::new(false),
        focus: Signal::new(true),
    });
    gamekit::sounds(SOUNDS);
    gamekit::autosave(SAVE_KEY, {
        let ui = ui.clone();
        move || ui.board.borrow().save_state(ui.difficulty.get())
    });
    Effect::new({
        let ui = ui.clone();
        move || {
            gamekit::save(
                SETTINGS_KEY,
                &Settings {
                    sounds: ui.sounds.get(),
                    vibrations: ui.vibrations.get(),
                    instructions_shown: true,
                    difficulty: ui.difficulty.get(),
                },
            );
        }
    });
    if !settings.instructions_shown {
        ui.push(Overlay::Instructions);
    }
    gamekit::on_background(SAVE_KEY, {
        let ui = ui.clone();
        move || ui.pause()
    });

    let board = board_canvas(ui.clone());
    let clock = {
        let (cu, bu) = (ui.clone(), ui.clone());
        when(
            move || cu.overlay.get() == Overlay::None,
            move || mines_clock(bu.clone()),
        )
    };
    let pu = ui.clone();
    let content = chrome::game_frame(
        chrome::game_header(tr("nav_mines"), "mi-pause", move || pu.pause()),
        Some(info_bar(ui.clone())),
        board.any(),
        Some(flag_toggle(ui.clone())),
    );
    zstack((content, overlays(ui), clock)).any()
}

fn board_canvas(ui: Rc<Ui>) -> impl Piece {
    let (du, tu, gu, ku) = (ui.clone(), ui.clone(), ui.clone(), ui.clone());
    canvas(move |d, sz| {
        du.repaint.track();
        du.field.set(sz);
        du.lay.set(lay(&du.board.borrow(), sz));
        draw_board(&du, d, sz);
    })
    .on_tap_at(move |p| {
        if tu.overlay.get_untracked() != Overlay::None {
            return;
        }
        // The drag's end or a hold may already have acted on this press.
        if !claim_at_tap(&mut tu.press.borrow_mut()) {
            return;
        }
        let hit = {
            let b = tu.board.borrow();
            tu.lay.get().hit(&b, p)
        };
        if let Some(i) = hit {
            tu.cursor.set(None);
            tu.tap(i);
        }
    })
    .on_drag(move |dg| {
        if gu.overlay.get_untracked() != Overlay::None {
            return;
        }
        match dg.phase {
            DragPhase::Began => {
                let hit = {
                    let b = gu.board.borrow();
                    gu.lay.get().hit(&b, dg.location)
                };
                *gu.press.borrow_mut() = hit.map(|cell| Press {
                    cell,
                    age: 0.0,
                    moved: false,
                    handled: false,
                });
                gu.repaint.notify();
            }
            DragPhase::Ended => {
                let acted = claim_at_release(&mut gu.press.borrow_mut());
                if acted {
                    let hit = {
                        let b = gu.board.borrow();
                        gu.lay.get().hit(&b, dg.location)
                    };
                    if let Some(i) = hit {
                        gu.cursor.set(None);
                        gu.tap(i);
                    }
                }
                gu.repaint.notify();
            }
            _ => {
                let far = dg.translation.x.abs().max(dg.translation.y.abs()) > SLOP;
                if far && let Some(p) = gu.press.borrow_mut().as_mut() {
                    p.moved = true;
                }
            }
        }
    })
    .on_key(move |k| ku.key(&k.key))
    .focused(ui.focus)
    .a11y(|a| a.label(tr("mi_board_a11y").format()))
    .id("mi-board")
    .grow()
}

/// The frame consumer: the clock, the effects, the press that becomes a flag, and the card a
/// finished board earns.
fn mines_clock(ui: Rc<Ui>) -> impl Piece {
    frame_clock(move |dt| {
        let dt = dt.as_secs_f64().min(0.05);
        {
            let mut b = ui.board.borrow_mut();
            b.tick(dt);
            let whole = b.elapsed.floor() as u32;
            drop(b);
            if ui.seen_second.replace(whole) != whole {
                ui.hud.notify();
            }
        }
        ui.fx.borrow_mut().step(dt);
        // A press held in place plants a flag, and says so, without waiting for the finger.
        let held = {
            let mut press = ui.press.borrow_mut();
            match press.as_mut() {
                Some(p) if !p.handled && !p.moved => {
                    p.age += dt;
                    (p.age >= HOLD).then(|| {
                        p.handled = true;
                        p.cell
                    })
                }
                _ => None,
            }
        };
        if let Some(i) = held {
            ui.hold(i);
        }
        let (boom, win) = {
            let fx = ui.fx.borrow();
            (fx.boom.map(|(_, age)| age), fx.win)
        };
        if ui.overlay.get_untracked() == Overlay::None {
            if boom.is_some_and(|age| age >= BOOM_HOLD) {
                ui.show(Overlay::Lost);
            } else if win.is_some_and(|age| age >= WIN_HOLD) {
                ui.show(Overlay::Won);
            }
        }
        ui.repaint.notify();
    })
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

fn draw_board(ui: &Ui, d: &mut Draw, sz: Size) {
    let board = ui.board.borrow();
    let fx = ui.fx.borrow();
    let l = lay(&board, sz);
    d.fill(
        Shape::Rect(Rect::new(0.0, 0.0, sz.width, sz.height)),
        SURFACE,
    );
    // The whole board shakes when a mine goes off.
    let shake = match fx.boom {
        Some((_, age)) if age < SHAKE => {
            let fade = 1.0 - age / SHAKE;
            let a = age * 46.0;
            (a.sin() * 7.0 * fade, (a * 1.7).cos() * 5.0 * fade)
        }
        _ => (0.0, 0.0),
    };
    d.transformed(Affine::translate(shake.0, shake.1), |d| {
        d.fill(
            Shape::RoundedRect(
                Rect::new(
                    l.ox - 5.0,
                    l.oy - 5.0,
                    l.cell * board.cols as f64 + 10.0,
                    l.cell * board.rows as f64 + 10.0,
                ),
                10.0,
            ),
            BOARD_BG,
        );
        let pressed = ui
            .press
            .borrow()
            .as_ref()
            .filter(|p| !p.handled && !p.moved)
            .map(|p| p.cell);
        for i in 0..board.cells() {
            draw_cell(d, &board, &fx, &l, i, pressed, ui.cursor.get());
        }
        // The explosion's ring.
        if let Some((i, age)) = fx.boom
            && age < 0.6
        {
            let c = l.center(&board, i);
            let r = l.cell * (0.5 + age * 6.0);
            let a = (1.0 - age / 0.6).powi(2);
            d.stroke(
                Shape::Ellipse(Rect::new(c.x - r, c.y - r, 2.0 * r, 2.0 * r)),
                Color::rgba(1.0, 0.55, 0.25, a),
                3.0,
            );
        }
        for s in &fx.sparks {
            let a = (1.0 - s.age / s.life).clamp(0.0, 1.0);
            let r = 2.0 + 2.0 * a;
            d.fill(
                Shape::Ellipse(Rect::new(s.x - r, s.y - r, 2.0 * r, 2.0 * r)),
                s.color.with_alpha(a),
            );
        }
    });
}

fn draw_cell(
    d: &mut Draw,
    board: &Board,
    fx: &Fx,
    l: &Lay,
    i: usize,
    pressed: Option<usize>,
    cursor: Option<usize>,
) {
    let r = l.rect(board, i);
    let gap = (l.cell * 0.06).clamp(0.7, 3.0);
    let face = Rect::new(
        r.origin.x + gap,
        r.origin.y + gap,
        r.size.width - 2.0 * gap,
        r.size.height - 2.0 * gap,
    );
    let radius = (l.cell * 0.16).clamp(2.0, 8.0);
    let center = Point::new(
        face.origin.x + face.size.width / 2.0,
        face.origin.y + face.size.height / 2.0,
    );
    let lost = board.lost_at;
    let state = board.state[i];
    let covered = state != Square::Revealed;
    // A lost game shows every mine, and crosses out the flags that were wrong.
    let show_mine = lost.is_some() && board.mine[i] && state != Square::Flagged;
    let wrong_flag = lost.is_some() && state == Square::Flagged && !board.mine[i];

    if covered && !show_mine {
        let sunk = pressed == Some(i);
        let scale = if sunk { 0.94 } else { 1.0 };
        let f = scaled(face, scale);
        d.fill(
            Shape::RoundedRect(f, radius),
            if sunk { OPEN } else { FACE },
        );
        if !sunk {
            // A lit top edge: the face reads as a button.
            d.fill(
                Shape::RoundedRect(
                    Rect::new(f.origin.x, f.origin.y, f.size.width, f.size.height * 0.42),
                    radius,
                ),
                FACE_TOP,
            );
            d.fill(
                Shape::RoundedRect(
                    Rect::new(
                        f.origin.x,
                        f.origin.y + f.size.height * 0.3,
                        f.size.width,
                        f.size.height * 0.7,
                    ),
                    radius,
                ),
                FACE,
            );
        }
        if state == Square::Flagged {
            let plant = fx.flag_of(i).unwrap_or(1.0);
            draw_flag(d, center, l.cell, plant, wrong_flag);
        }
    } else {
        d.fill(Shape::RoundedRect(face, radius), OPEN);
        d.stroke(Shape::RoundedRect(face, radius), OPEN_EDGE, 1.0);
        if show_mine {
            if lost == Some(i) {
                d.fill(Shape::RoundedRect(face, radius), BOOM_RED);
            }
            draw_mine(d, center, l.cell);
        } else {
            let n = board.near[i];
            if n > 0 {
                let pop = fx.pop_of(i);
                let (scale, alpha) = match pop {
                    // Opening: the digit swells in as its square clears.
                    Some(t) => (0.6 + 0.4 * ease_out(t), ease_out(t)),
                    None => (1.0, 1.0),
                };
                d.text(
                    &n.to_string(),
                    center,
                    TextStyle {
                        size: l.cell * 0.56 * scale,
                        color: NUMBERS[(n as usize - 1).min(7)].with_alpha(alpha),
                        anchor: TextAnchor::CENTERED,
                        font: chrome::canvas_font(FontWeight::Black),
                    },
                );
            }
        }
    }
    // A square mid-pop draws its old face over the top, shrinking away.
    if let Some(t) = fx.pop_of(i)
        && !covered
        && !show_mine
    {
        let e = ease_out(t);
        let f = scaled(face, 1.0 - e);
        d.fill(
            Shape::RoundedRect(f, radius * (1.0 - e).max(0.2)),
            FACE.with_alpha(1.0 - e),
        );
    }
    if cursor == Some(i) {
        d.stroke(Shape::RoundedRect(face, radius), CURSOR, 2.0);
    }
}

fn scaled(r: Rect, s: f64) -> Rect {
    let (w, h) = (r.size.width * s, r.size.height * s);
    Rect::new(
        r.origin.x + (r.size.width - w) / 2.0,
        r.origin.y + (r.size.height - h) / 2.0,
        w,
        h,
    )
}

fn ease_out(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    1.0 - (1.0 - t) * (1.0 - t)
}

/// A flag on a pole, planted with a little overshoot.
fn draw_flag(d: &mut Draw, c: Point, cell: f64, plant: f64, wrong: bool) {
    let e = ease_out(plant);
    let lean = (1.0 - e) * 0.5;
    let s = cell * 0.34 * (0.7 + 0.3 * e);
    d.transformed(
        Affine::translate(-c.x, -c.y)
            .then(Affine::rotate(lean))
            .then(Affine::translate(c.x, c.y)),
        |d| {
            d.fill(
                Shape::Rect(Rect::new(c.x - s * 0.08, c.y - s, s * 0.16, s * 1.9)),
                FLAG_POLE,
            );
            d.fill(
                Shape::Rect(Rect::new(c.x - s * 0.5, c.y + s * 0.75, s, s * 0.2)),
                FLAG_POLE,
            );
            d.fill(
                PathBuilder::new()
                    .move_to(Point::new(c.x + s * 0.08, c.y - s))
                    .line_to(Point::new(c.x + s * 0.08 + s, c.y - s * 0.55))
                    .line_to(Point::new(c.x + s * 0.08, c.y - s * 0.1))
                    .close()
                    .build(),
                if wrong {
                    Color::rgba(0.6, 0.6, 0.65, 0.9)
                } else {
                    FLAG_RED
                },
            );
        },
    );
    if wrong {
        let x = cell * 0.3;
        chrome::draw_cross_glyph(d, c, x, Color::rgba(1.0, 0.4, 0.4, 0.95));
    }
}

/// A mine: a dark ball with spikes and a glint.
fn draw_mine(d: &mut Draw, c: Point, cell: f64) {
    let r = cell * 0.24;
    for k in 0..8 {
        let a = k as f64 * TAU / 8.0;
        let (dx, dy) = (a.cos(), a.sin());
        d.stroke(
            Shape::Line(
                Point::new(c.x + dx * r * 0.7, c.y + dy * r * 0.7),
                Point::new(c.x + dx * r * 1.6, c.y + dy * r * 1.6),
            ),
            MINE_DARK,
            (cell * 0.07).max(1.2),
        );
    }
    d.fill(
        Shape::Ellipse(Rect::new(c.x - r, c.y - r, 2.0 * r, 2.0 * r)),
        MINE_DARK,
    );
    let g = r * 0.3;
    d.fill(
        Shape::Ellipse(Rect::new(
            c.x - r * 0.45 - g / 2.0,
            c.y - r * 0.45 - g / 2.0,
            g * 1.6,
            g * 1.6,
        )),
        Color::rgba(1.0, 1.0, 1.0, 0.55),
    );
}

// ---------------------------------------------------------------------------
// The HUD
// ---------------------------------------------------------------------------

/// The readouts under the header: mines left, and the clock.
fn info_bar(ui: Rc<Ui>) -> AnyPiece {
    let (mu, tu) = (ui.clone(), ui.clone());
    let mines = counter(
        tr("mi_mines_left"),
        move || {
            mu.hud.track();
            mu.board.borrow().mines_left().to_string()
        },
        FLAG_RED,
        "mi-mines-left",
    );
    let time = counter(
        tr("mi_time"),
        move || {
            tu.hud.track();
            fmt_time(tu.board.borrow().elapsed)
        },
        Color::WHITE,
        "mi-time",
    );
    chrome::info_row(vec![mines, time])
}

/// Under the board: Flag Mode, the one control a game of Mines keeps reaching for.
fn flag_toggle(ui: Rc<Ui>) -> AnyPiece {
    let fu = ui.clone();
    let flag = {
        let on = ui.flag_mode;
        canvas(move |d, sz| {
            let c = Point::new(sz.width / 2.0, sz.height / 2.0);
            let lit = on.get();
            if lit {
                d.fill(
                    Shape::RoundedRect(Rect::new(2.0, 2.0, sz.width - 4.0, sz.height - 4.0), 10.0),
                    FLAG_RED.with_alpha(0.22),
                );
            }
            // The banner hangs to the right of the pole, so the glyph sits back from center to
            // land in the middle of the button rather than over its edge.
            let glyph = 48.0;
            draw_flag(d, Point::new(c.x - glyph * 0.1, c.y), glyph, 1.0, false);
            if !lit {
                // Off: the flag sits back, a hint rather than a state.
                d.fill(
                    Shape::RoundedRect(Rect::new(2.0, 2.0, sz.width - 4.0, sz.height - 4.0), 10.0),
                    SURFACE.with_alpha(0.45),
                );
            }
        })
        .on_tap(move || {
            let now = !fu.flag_mode.get_untracked();
            fu.flag_mode.set(now);
            fu.cue(&cues::TICK);
            fu.hud.notify();
        })
        .a11y(|a| a.label(tr("mi_flag_mode_a11y").format()).role(Role::Button))
        .id("mi-flag-mode")
        .frame(44.0, 44.0)
    };
    row((label(tr("mi_flag_mode")).color(chrome::TEXT), flag))
        .spacing(10.0)
        .align(VAlign::Center)
        .padding(8.0)
        .any()
}

fn counter(
    caption: day_fluent::LocalizedText,
    value: impl Fn() -> String + 'static,
    color: Color,
    id: &'static str,
) -> AnyPiece {
    column((
        label(caption).font(Font::Caption).color(chrome::TEXT_DIM),
        label(value)
            .font(Font::Title3)
            .bold()
            .tabular()
            .color(color)
            .id(id),
    ))
    .spacing(0.0)
    .align(HAlign::Center)
    // Room for three digits from the first layout, so a counter never resizes its row.
    .min_width(54.0)
    .any()
}

// ---------------------------------------------------------------------------
// Cards
// ---------------------------------------------------------------------------

fn overlays(ui: Rc<Ui>) -> impl Piece {
    let scrim = {
        let u = ui.clone();
        when(move || u.overlay.get() != Overlay::None, chrome::scrim)
    };
    let (p, k, w, l, s, i) = (
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
        card(Overlay::Picker, Rc::new(move || picker_card(k.clone()))),
        card(Overlay::Won, Rc::new(move || won_card(w.clone()))),
        card(Overlay::Lost, Rc::new(move || lost_card(l.clone()))),
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
            chrome::menu_button(tr("gk_resume"), chrome::GREEN, "mi-resume", move || {
                u1.show(Overlay::None)
            }),
            chrome::menu_button(tr("gk_new_game"), chrome::BLUE, "mi-new-game", move || {
                u2.push(Overlay::Picker)
            }),
            chrome::menu_button(tr("gk_settings"), chrome::SLATE, "mi-settings", move || {
                u3.push(Overlay::Settings)
            }),
            chrome::menu_button(
                tr("gk_instructions"),
                chrome::INDIGO,
                "mi-instructions",
                move || u4.push(Overlay::Instructions),
            ),
            chrome::menu_button(tr("gk_quit"), chrome::RED, "mi-quit", || {
                nav_back();
            }),
        ))
        .spacing(14.0)
        .align(HAlign::Center),
    )
    .id("mi-pause-menu")
    .any()
}

/// Choosing a board: each difficulty with the shape it will take in this window.
fn picker_card(ui: Rc<Ui>) -> AnyPiece {
    let field = ui.field.get();
    let landscape = field.width > field.height * 1.05;
    let current = ui.difficulty.get();
    let mut rows = Vec::new();
    for d in DIFFICULTIES {
        let u = ui.clone();
        let tint = difficulty_tint(d);
        let (cols, board_rows) = d.shape(landscape);
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
        rows.push(
            row((
                column((
                    label(difficulty_label(d))
                        .font(Font::Title3)
                        .bold()
                        .color(Color::WHITE),
                    label(
                        tr("mi_board_detail")
                            .arg("cols", cols as f64)
                            .arg("rows", board_rows as f64)
                            .arg("mines", d.mines() as f64),
                    )
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
            .a11y(move |a| a.label(difficulty_label(d).format()).role(Role::Button))
            .id(difficulty_id(d))
            .width(300.0)
            .any(),
        );
    }
    let u = ui;
    chrome::card(
        column((
            label(tr("mi_choose"))
                .font(Font::Title2)
                .bold()
                .color(Color::WHITE),
            column(PieceVec(rows)).spacing(12.0),
            button(tr("gk_cancel"))
                .action(move || u.pop())
                .id("mi-cancel"),
        ))
        .spacing(16.0)
        .align(HAlign::Center),
    )
    .id("mi-picker")
    .any()
}

/// The two end cards share a shape: a headline, the time, and what to do next.
fn end_card(ui: Rc<Ui>, won: bool) -> AnyPiece {
    let d = ui.difficulty.get();
    let secs = ui.board.borrow().elapsed;
    let best = ui.records.borrow().best[d.index()];
    let new_best = ui.new_best.get();
    let (again_label, again_id) = if won {
        (tr("gk_play_again"), "mi-play-again")
    } else {
        (tr("mi_try_again"), "mi-try-again")
    };
    let (au, nu) = (ui.clone(), ui.clone());
    let best_line = when(
        move || best.is_some(),
        move || {
            chrome::stat(
                tr("mi_best_time"),
                best.map(fmt_time).unwrap_or_default(),
                Font::Title3,
                Color::WHITE,
                "mi-best",
            )
        },
    );
    let record = when(
        move || new_best,
        || {
            label(tr("mi_new_best"))
                .font(Font::Headline)
                .bold()
                .color(chrome::GOLD)
        },
    );
    chrome::card(
        column((
            chrome::card_title(
                if won { tr("mi_swept") } else { tr("mi_boom") },
                if won { chrome::GOLD } else { FLAG_RED },
            ),
            label(difficulty_label(d))
                .font(Font::Headline)
                .color(chrome::TEXT_DIM),
            chrome::stat(
                tr("mi_time"),
                fmt_time(secs),
                Font::LargeTitle,
                if won { chrome::GOLD } else { Color::WHITE },
                "mi-final-time",
            ),
            best_line,
            record,
            chrome::menu_button(again_label, chrome::GREEN, again_id, move || au.new_game(d)),
            chrome::menu_button(
                tr("gk_new_game"),
                chrome::BLUE,
                "mi-end-new-game",
                move || nu.push(Overlay::Picker),
            ),
            chrome::menu_button(tr("gk_quit"), chrome::RED, "mi-end-quit", || {
                nav_back();
            }),
        ))
        .spacing(12.0)
        .align(HAlign::Center),
    )
    .id(if won { "mi-won-card" } else { "mi-lost-card" })
    .any()
}

fn won_card(ui: Rc<Ui>) -> AnyPiece {
    end_card(ui, true)
}

fn lost_card(ui: Rc<Ui>) -> AnyPiece {
    end_card(ui, false)
}

fn settings_card(ui: Rc<Ui>) -> AnyPiece {
    let records = ui.records.borrow().clone();
    let line = |d: Difficulty| {
        let i = d.index();
        let best = records.best[i].map(fmt_time).unwrap_or_else(|| "—".into());
        row((
            column((
                label(difficulty_label(d)).color(chrome::TEXT),
                label(
                    tr("mi_record_line")
                        .arg("won", f64::from(records.won[i]))
                        .arg("played", f64::from(records.played[i])),
                )
                .font(Font::Caption)
                .color(chrome::TEXT_DIM),
            ))
            .spacing(2.0)
            .align(HAlign::Leading)
            .grow_w(),
            label(best).tabular().color(chrome::TEXT_DIM),
        ))
        .align(VAlign::Center)
        .width(300.0)
        .any()
    };
    let reset = {
        let u = ui.clone();
        button(tr("mi_reset_records"))
            .tint(chrome::RED)
            .action(move || {
                let u = u.clone();
                day_core::task(async move {
                    let sure = Alert::new(tr("mi_reset_records_title"))
                        .message(tr("mi_reset_records_message"))
                        .destructive(tr("gk_reset_confirm"), true)
                        .cancel(tr("gk_cancel"))
                        .present()
                        .await;
                    if sure == Some(true) {
                        *u.records.borrow_mut() = Records::default();
                        gamekit::save(RECORDS_KEY, &*u.records.borrow());
                        u.show(Overlay::Settings);
                    }
                });
            })
            .id("mi-reset-records")
    };
    let done = ui.clone();
    chrome::card(
        column((
            label(tr("gk_settings"))
                .font(Font::Title2)
                .bold()
                .color(Color::WHITE),
            chrome::section_heading(tr("nav_mines")),
            chrome::setting_row(tr("gk_sounds"), toggle(ui.sounds).id("mi-sounds").any()),
            chrome::setting_row(
                tr("gk_vibrations"),
                toggle(ui.vibrations).id("mi-vibrations").any(),
            ),
            chrome::setting_row(
                tr("mi_flag_mode"),
                toggle(ui.flag_mode).id("mi-flag-setting").any(),
            ),
            chrome::section_heading(tr("mi_records")),
            line(Difficulty::Easy),
            line(Difficulty::Medium),
            line(Difficulty::Hard),
            reset,
            button(tr("gk_done"))
                .prominent()
                .action(move || done.pop())
                .id("mi-done"),
        ))
        .spacing(12.0)
        .align(HAlign::Center),
    )
    .id("mi-settings-card")
    .any()
}

fn instructions_card(ui: Rc<Ui>) -> AnyPiece {
    chrome::instructions_card(
        tr("nav_mines"),
        vec![
            Help::Para(tr("mi_help_intro")),
            Help::Heading(tr("mi_help_play")),
            Help::Para(tr("mi_help_play_1")),
            Help::Para(tr("mi_help_play_2")),
            Help::Para(tr("mi_help_play_3")),
            Help::Para(tr("mi_help_play_4")),
            Help::Heading(tr("mi_help_keys")),
            Help::Para(tr("mi_help_keys_1")),
        ],
        "mi-help-done",
        move || ui.pop(),
    )
    .id("mi-instructions-card")
    .any()
}

// ---------------------------------------------------------------------------
// The home tile
// ---------------------------------------------------------------------------

/// The home-screen tile: a corner of a board mid-game, drawn with the same cells as gameplay.
pub fn mines_preview() -> AnyPiece {
    canvas(|d, sz| {
        d.fill(
            Shape::Rect(Rect::new(0.0, 0.0, sz.width, sz.height)),
            SURFACE,
        );
        let n = 5;
        // A tile is measured at nothing before it has room, and a negative cell would take every
        // radius below it negative with it.
        let cell = ((sz.width.min(sz.height) - 16.0) / n as f64).max(1.0);
        let ox = (sz.width - cell * n as f64) / 2.0;
        let oy = (sz.height - cell * n as f64) / 2.0;
        d.fill(
            Shape::RoundedRect(
                Rect::new(
                    ox - 5.0,
                    oy - 5.0,
                    cell * n as f64 + 10.0,
                    cell * n as f64 + 10.0,
                ),
                10.0,
            ),
            BOARD_BG,
        );
        // A swept corner with its numbers, a planted flag, and one mine still hiding.
        let open = [
            (0, 0, 0u8),
            (1, 0, 1),
            (2, 0, 1),
            (0, 1, 0),
            (1, 1, 1),
            (0, 2, 0),
            (1, 2, 2),
            (2, 2, 3),
            (0, 3, 1),
            (1, 3, 2),
        ];
        let flags = [(3, 1), (4, 3)];
        let mine = (3, 3);
        for r in 0..n {
            for c in 0..n {
                let rect = Rect::new(ox + c as f64 * cell, oy + r as f64 * cell, cell, cell);
                let gap = cell * 0.07;
                let face = Rect::new(
                    rect.origin.x + gap,
                    rect.origin.y + gap,
                    rect.size.width - 2.0 * gap,
                    rect.size.height - 2.0 * gap,
                );
                let radius = cell * 0.16;
                let center = Point::new(
                    face.origin.x + face.size.width / 2.0,
                    face.origin.y + face.size.height / 2.0,
                );
                if let Some(&(_, _, n)) = open.iter().find(|(oc, or, _)| *oc == c && *or == r) {
                    d.fill(Shape::RoundedRect(face, radius), OPEN);
                    if n > 0 {
                        d.text(
                            &n.to_string(),
                            center,
                            TextStyle {
                                size: cell * 0.56,
                                color: NUMBERS[(n as usize - 1).min(7)],
                                anchor: TextAnchor::CENTERED,
                                font: chrome::canvas_font(FontWeight::Black),
                            },
                        );
                    }
                } else {
                    d.fill(Shape::RoundedRect(face, radius), FACE);
                    d.fill(
                        Shape::RoundedRect(
                            Rect::new(
                                face.origin.x,
                                face.origin.y,
                                face.size.width,
                                face.size.height * 0.42,
                            ),
                            radius,
                        ),
                        FACE_TOP,
                    );
                    d.fill(
                        Shape::RoundedRect(
                            Rect::new(
                                face.origin.x,
                                face.origin.y + face.size.height * 0.3,
                                face.size.width,
                                face.size.height * 0.7,
                            ),
                            radius,
                        ),
                        FACE,
                    );
                    if flags.contains(&(c, r)) {
                        draw_flag(d, center, cell, 1.0, false);
                    } else if (c, r) == mine {
                        draw_mine(d, center, cell);
                    }
                }
            }
        }
    })
    .any()
}
