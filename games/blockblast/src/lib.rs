//! Block Blast — drag pieces from a three-piece tray onto an 8×8 board; a full row or column
//! clears. One immediate-mode canvas (docs/canvas.md) draws the board, the tray and every effect,
//! stepped on Day's frame clock: a picked-up piece grows to board size and rides above the
//! finger, a shadow and a glow preview where it lands and which lines it would complete, placed
//! blocks squash, cleared blocks flash and tumble out in a wave with particle bursts, the board
//! shakes and pulses with the size of the clear, points float up, a call-out names the moment,
//! an emptied board rains confetti, and the board grays out row by row when no piece fits.
//! On a keyboard, 1–3 pick up a piece, the arrows move it, and the same digit drops it. The
//! rules live in model.rs.

use std::cell::{Cell, RefCell};
use std::f64::consts::{PI, TAU};
use std::rc::Rc;

use day_fluent::tr;
use day_geometry::Affine;
use day_part_haptics::Haptic;
use day_pieces::prelude::*;
use gamekit::chrome::cues::{self, with};
use gamekit::chrome::{self, Cue, Feedback, Help, Pattern, Sfx, sfx};

mod model;
use model::{CELLS, DIFFICULTIES, Difficulty, Model, N, Placement, TRAY};

/// The prefs keys this game persists under (gamekit; bump the game key on a schema change).
const SAVE_KEY: &str = "blockblast.v1";
const RECORD_KEY: &str = "blockblast.best";
const SETTINGS_KEY: &str = "blockblast.settings";

const BG_TOP: Color = Color::rgb(0.12, 0.13, 0.25);
/// The game's cover surface color (edge-to-edge behind the safe area).
pub const SURFACE: Color = Color::rgb(0.08, 0.08, 0.18);
const BOARD_BG: Color = Color::rgb(0.10, 0.11, 0.24);
const BOARD_RIM: Color = Color::rgba(1.0, 1.0, 1.0, 0.10);
const SLOT: Color = Color::rgba(1.0, 1.0, 1.0, 0.055);
const DIM: Color = Color::rgb(0.04, 0.04, 0.10);

/// The block palette: a body color with its lit top and shaded bottom, indexed by piece color.
const BASE: [Color; 8] = [
    Color::rgb(0.96, 0.30, 0.33),
    Color::rgb(1.00, 0.58, 0.20),
    Color::rgb(1.00, 0.82, 0.22),
    Color::rgb(0.33, 0.83, 0.42),
    Color::rgb(0.22, 0.78, 0.95),
    Color::rgb(0.33, 0.45, 1.00),
    Color::rgb(0.68, 0.40, 1.00),
    Color::rgb(1.00, 0.40, 0.70),
];
const LIGHT: [Color; 8] = [
    Color::rgb(1.00, 0.52, 0.54),
    Color::rgb(1.00, 0.74, 0.45),
    Color::rgb(1.00, 0.92, 0.52),
    Color::rgb(0.56, 0.93, 0.62),
    Color::rgb(0.50, 0.90, 1.00),
    Color::rgb(0.56, 0.65, 1.00),
    Color::rgb(0.82, 0.62, 1.00),
    Color::rgb(1.00, 0.62, 0.83),
];
const DARK: [Color; 8] = [
    Color::rgb(0.66, 0.14, 0.18),
    Color::rgb(0.72, 0.36, 0.08),
    Color::rgb(0.74, 0.56, 0.06),
    Color::rgb(0.16, 0.56, 0.24),
    Color::rgb(0.08, 0.50, 0.70),
    Color::rgb(0.18, 0.26, 0.74),
    Color::rgb(0.44, 0.20, 0.74),
    Color::rgb(0.72, 0.20, 0.46),
];

/// Tray pieces are drawn at this fraction of a board cell.
const TRAY_SCALE: f64 = 0.56;
/// The board never grows past this on a large desktop window.
const MAX_BOARD: f64 = 460.0;
/// How far above a finger a dragged piece's center rides, in board cells, so the finger never
/// covers it. A mouse drags the piece from its middle.
const LIFT_TOUCH: f64 = 2.3;

const GROW_DUR: f64 = 0.14;
const RETURN_DUR: f64 = 0.24;
const SQUASH_DUR: f64 = 0.32;
const FLASH_DUR: f64 = 0.10;
const TUMBLE_DUR: f64 = 0.46;
/// The clear wave: each cleared cell waits this long per cell of distance from the drop.
const WAVE: f64 = 0.028;
const DEAL_DUR: f64 = 0.30;
const DEAL_STAGGER: f64 = 0.07;
const SHAKE_DUR: f64 = 0.34;
const PULSE_DUR: f64 = 0.40;
const POPUP_LIFE: f64 = 1.2;
const BANNER_LIFE: f64 = 1.25;
const BANNER_LIFE_PERFECT: f64 = 1.9;
const CONFETTI_LIFE: f64 = 2.6;
const PARTICLE_GRAVITY: f64 = 900.0;
/// The game-over sweep: a pause for the last move to land, then the rows gray out bottom up.
const OVER_DELAY: f64 = 0.45;
const OVER_ROW: f64 = 0.07;
const OVER_FADE: f64 = 0.25;
const OVER_DUR: f64 = OVER_DELAY + OVER_ROW * (N as f64 - 1.0) + OVER_FADE + 0.35;

// Haptic phrases for the clear tiers (gamekit::chrome's vocabulary, one style per beat).
const TIER1: Pattern = &[(0, Haptic::Heavy), (80, Haptic::Success)];
const TIER2: Pattern = &[
    (0, Haptic::Heavy),
    (70, Haptic::Medium),
    (140, Haptic::Heavy),
];
const TIER3: Pattern = &[
    (0, Haptic::Heavy),
    (90, Haptic::Success),
    (190, Haptic::Light),
    (290, Haptic::Medium),
];
const TIER4: Pattern = &[
    (0, Haptic::Heavy),
    (70, Haptic::Medium),
    (140, Haptic::Heavy),
    (230, Haptic::Success),
    (330, Haptic::Heavy),
];
const TIER5: Pattern = &[
    (0, Haptic::Heavy),
    (60, Haptic::Heavy),
    (140, Haptic::Medium),
    (220, Haptic::Success),
    (320, Haptic::Heavy),
    (440, Haptic::Success),
];
const PERFECT: Pattern = &[
    (0, Haptic::Success),
    (110, Haptic::Heavy),
    (170, Haptic::Heavy),
    (240, Haptic::Medium),
    (300, Haptic::Light),
    (370, Haptic::Medium),
    (450, Haptic::Heavy),
    (600, Haptic::Success),
    (760, Haptic::Success),
];
/// Timed to the gray sweep that starts after the last move lands.
const OUT_OF_MOVES: Pattern = &[
    (450, Haptic::Heavy),
    (620, Haptic::Heavy),
    (820, Haptic::Error),
];

// Sounds, each with the haptic it plays beside (gamekit::chrome::Cue).
const PLACE_SFX: Sfx = sfx("sounds/blockblast/place.wav");
static LIFT: Cue = with("sounds/blockblast/lift.wav", cues::LIGHT_BEAT);
static PLACE: Cue = with("sounds/blockblast/place.wav", cues::MEDIUM_BEAT);
static PLACE_BIG: Cue = with("sounds/blockblast/place_big.wav", cues::HEAVY_BEAT);
static CANCEL: Cue = with("sounds/blockblast/cancel.wav", cues::LIGHT_BEAT);
/// A clear's call-out, by tier: a longer phrase for a bigger clear.
static CLEARS: [Cue; 5] = [
    with("sounds/blockblast/clear_1.wav", TIER1),
    with("sounds/blockblast/clear_2.wav", TIER2),
    with("sounds/blockblast/clear_3.wav", TIER3),
    with("sounds/blockblast/clear_4.wav", TIER4),
    with("sounds/blockblast/clear_5.wav", TIER5),
];
static PERFECT_CUE: Cue = with("sounds/blockblast/perfect.wav", PERFECT);
static RECORD: Cue = with("sounds/blockblast/record.wav", chrome::CELEBRATE);
/// Out of moves: the ending sounds with the gray sweep, as the haptic does.
static OUT_OF_MOVES_CUE: Cue = Cue {
    sound: Some(sfx("sounds/shared/over_puzzle.wav")),
    sound_at: 450,
    volume: 1.0,
    haptic: OUT_OF_MOVES,
};

/// Every clip this game plays besides the shared ones (gamekit preloads both).
pub const SOUNDS: &[Sfx] = &[
    sfx("sounds/blockblast/lift.wav"),
    sfx("sounds/blockblast/place.wav"),
    sfx("sounds/blockblast/place_big.wav"),
    sfx("sounds/blockblast/cancel.wav"),
    sfx("sounds/blockblast/clear_1.wav"),
    sfx("sounds/blockblast/clear_2.wav"),
    sfx("sounds/blockblast/clear_3.wav"),
    sfx("sounds/blockblast/clear_4.wav"),
    sfx("sounds/blockblast/clear_5.wav"),
    sfx("sounds/blockblast/perfect.wav"),
    sfx("sounds/blockblast/record.wav"),
];

fn ease_out(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    1.0 - (1.0 - t).powi(3)
}

/// Overshoots its target a little before settling: a pop.
fn ease_out_back(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    let (c1, c3) = (1.70158, 2.70158);
    1.0 + c3 * (t - 1.0).powi(3) + c1 * (t - 1.0).powi(2)
}

fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + (b - a) * t
}

/// One block in a `size` square at `(x, y)`: a beveled gem in palette `color`, scaled about its
/// center, at opacity `alpha`. The board, the tray, a dragged piece, the clear ghosts and the
/// home-tile preview all draw blocks with it.
fn draw_block(d: &mut Draw, x: f64, y: f64, size: f64, color: u8, alpha: f64, scale: f64) {
    let c = (color as usize) % BASE.len();
    let inset = (size * 0.05).max(0.8);
    let s = (size - 2.0 * inset) * scale;
    if s <= 0.5 || alpha <= 0.0 {
        return;
    }
    let (bx, by) = (x + (size - s) / 2.0, y + (size - s) / 2.0);
    let r = s * 0.18;
    // The shaded base shows as a lip along the bottom, under the lit body.
    d.fill(
        Shape::RoundedRect(Rect::new(bx, by, s, s), r),
        DARK[c].with_alpha(alpha),
    );
    d.fill(
        Shape::RoundedRect(Rect::new(bx, by, s, s * 0.86), r),
        LinearGradient::new(
            UnitPoint::TOP,
            UnitPoint::BOTTOM,
            vec![
                (0.0, LIGHT[c].with_alpha(alpha)),
                (1.0, BASE[c].with_alpha(alpha)),
            ],
        ),
    );
    d.fill(
        Shape::RoundedRect(
            Rect::new(bx + s * 0.16, by + s * 0.10, s * 0.68, s * 0.20),
            s * 0.10,
        ),
        Color::rgba(1.0, 1.0, 1.0, 0.30 * alpha),
    );
}

fn tier_color(tier: u8) -> Color {
    match tier {
        0 | 1 => Color::WHITE,
        2 => Color::rgb(0.40, 0.88, 1.00),
        3 => Color::rgb(1.00, 0.86, 0.25),
        4 => Color::rgb(1.00, 0.60, 0.20),
        5 => Color::rgb(1.00, 0.42, 0.74),
        _ => Color::rgb(1.00, 0.84, 0.30),
    }
}

/// A call-out for a clear of `tier`, the `pick`th of its pool. LITERAL `tr` keys, so `day lint`
/// tracks their coverage.
fn message(tier: u8, pick: usize) -> day_fluent::LocalizedText {
    match (tier, pick % 3) {
        (1, 0) => tr("bb_msg_nice"),
        (1, 1) => tr("bb_msg_good"),
        (1, _) => tr("bb_msg_sweet"),
        (2, 0) => tr("bb_msg_great"),
        (2, 1) => tr("bb_msg_smooth"),
        (2, _) => tr("bb_msg_slick"),
        (3, 0) => tr("bb_msg_awesome"),
        (3, 1) => tr("bb_msg_excellent"),
        (3, _) => tr("bb_msg_fantastic"),
        (4, 0) => tr("bb_msg_amazing"),
        (4, 1) => tr("bb_msg_incredible"),
        (4, _) => tr("bb_msg_spectacular"),
        (5, 0) => tr("bb_msg_unbelievable"),
        (5, 1) => tr("bb_msg_legendary"),
        (5, _) => tr("bb_msg_unstoppable"),
        (_, 0) => tr("bb_msg_perfect"),
        (_, _) => tr("bb_msg_flawless"),
    }
}

fn difficulty_label(d: Difficulty) -> day_fluent::LocalizedText {
    match d {
        Difficulty::Easy => tr("bb_easy"),
        Difficulty::Normal => tr("bb_normal"),
        Difficulty::Hard => tr("bb_hard"),
    }
}

fn difficulty_detail(d: Difficulty) -> day_fluent::LocalizedText {
    match d {
        Difficulty::Easy => tr("bb_detail_easy"),
        Difficulty::Normal => tr("bb_detail_normal"),
        Difficulty::Hard => tr("bb_detail_hard"),
    }
}

fn difficulty_id(d: Difficulty) -> &'static str {
    match d {
        Difficulty::Easy => "bb-diff-easy",
        Difficulty::Normal => "bb-diff-normal",
        Difficulty::Hard => "bb-diff-hard",
    }
}

fn accent(d: Difficulty) -> Color {
    match d {
        Difficulty::Easy => Color::rgb(0.35, 0.75, 0.45),
        Difficulty::Normal => Color::rgb(0.30, 0.60, 0.95),
        Difficulty::Hard => Color::rgb(0.90, 0.35, 0.30),
    }
}

struct FxRng(u64);

impl FxRng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
    fn range(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * ((self.next() >> 11) as f64 / (1u64 << 53) as f64)
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

/// Where the board and the tray sit in the canvas.
#[derive(Clone, Copy, Default)]
struct Layout {
    bx: f64,
    by: f64,
    side: f64,
    cell: f64,
    tray_y: f64,
    tray_h: f64,
    slot_w: f64,
    /// A tray block's size.
    mini: f64,
}

fn layout(sz: Size) -> Layout {
    let (pad, gap) = (12.0, 18.0);
    let avail_w = (sz.width - 2.0 * pad).max(40.0);
    let avail_h = (sz.height - 2.0 * pad - gap).max(40.0);
    // The tray holds pieces up to five mini cells tall, plus a margin.
    let tray_ratio = TRAY_SCALE * 5.0 / N as f64 + 0.06;
    let side = avail_w.min(avail_h / (1.0 + tray_ratio)).min(MAX_BOARD);
    let cell = side / N as f64;
    let tray_h = side * tray_ratio;
    let spare = (avail_h - side - tray_h).max(0.0);
    // Even space above and below the board and tray.
    let by = pad + spare * 0.5;
    Layout {
        bx: (sz.width - side) / 2.0,
        by,
        side,
        cell,
        tray_y: by + side + gap,
        tray_h,
        slot_w: side / TRAY as f64,
        mini: cell * TRAY_SCALE,
    }
}

/// The piece being moved: by a finger or pointer (`keys` is `None`) or by the keyboard.
#[derive(Clone, Copy)]
struct Held {
    slot: usize,
    /// The finger or pointer, in canvas coordinates.
    at: Point,
    /// How far above `at` the piece's center rides.
    lift: f64,
    /// Time since pick-up (the grow from tray size to board size).
    grow: f64,
    /// The top-left cell it would land on, when it fits there.
    snap: Option<(i32, i32)>,
    /// The keyboard's position for it, fitting or not.
    keys: Option<(i32, i32)>,
}

/// A piece flying back to its tray slot after a drop that did not fit.
struct Flight {
    slot: usize,
    from: (f64, f64, f64),
    age: f64,
}

struct Ghost {
    i: usize,
    color: u8,
    delay: f64,
    age: f64,
    spin: f64,
}

struct Particle {
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    delay: f64,
    life: f64,
    max: f64,
    color: u8,
    size: f64,
    angle: f64,
    spin: f64,
}

struct Popup {
    text: String,
    x: f64,
    y: f64,
    age: f64,
    size: f64,
    color: Color,
}

struct Banner {
    text: String,
    sub: Option<String>,
    tier: u8,
    age: f64,
}

struct Confetti {
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    angle: f64,
    spin: f64,
    color: u8,
    w: f64,
    h: f64,
    life: f64,
}

/// Everything on screen that is not the rules: the held piece and every tween and effect.
struct Fx {
    held: Option<Held>,
    flights: Vec<Flight>,
    squash: Vec<(usize, f64)>,
    ghosts: Vec<Ghost>,
    particles: Vec<Particle>,
    popups: Vec<Popup>,
    banner: Option<Banner>,
    confetti: Vec<Confetti>,
    shake: f64,
    shake_amp: f64,
    pulse: f64,
    pulse_amp: f64,
    /// Per tray slot, time since its piece was dealt (negative while it waits its turn).
    deal: [f64; TRAY],
    /// Time since the game-over sweep began.
    over: Option<f64>,
    /// The score and best as the HUD counts them up.
    shown_score: f64,
    shown_best: f64,
    /// Running time, for the glow on a previewed clear.
    t: f64,
    rng: FxRng,
}

impl Fx {
    fn new(seed: u64, score: i64, best: i64) -> Fx {
        Fx {
            held: None,
            flights: Vec::new(),
            squash: Vec::new(),
            ghosts: Vec::new(),
            particles: Vec::new(),
            popups: Vec::new(),
            banner: None,
            confetti: Vec::new(),
            shake: SHAKE_DUR,
            shake_amp: 0.0,
            pulse: PULSE_DUR,
            pulse_amp: 0.0,
            deal: [-0.10, -0.10 - DEAL_STAGGER, -0.10 - 2.0 * DEAL_STAGGER],
            over: None,
            shown_score: score as f64,
            shown_best: best as f64,
            t: 0.0,
            rng: FxRng(seed | 1),
        }
    }

    fn squash_scale(&self, i: usize) -> f64 {
        self.squash
            .iter()
            .find(|(c, _)| *c == i)
            .map_or(1.0, |&(_, age)| {
                let t = (age / SQUASH_DUR).clamp(0.0, 1.0);
                1.0 + 0.16 * (1.0 - t).powi(2) * (t * 3.0 * PI).cos()
            })
    }
}

/// The outcome of letting go of a piece.
enum Release {
    Placed(Placement),
    /// Dropped where it does not fit: it flies back.
    Returned,
    /// Put back down in the tray.
    Cancelled,
    Nothing,
}

/// The outcome of a key press.
enum KeyOutcome {
    Lifted,
    Moved { fits: bool },
    Released(Release),
    Refused,
    Nothing,
}

/// The rules plus their presentation, borrowed together by the canvas and its handlers.
struct Play {
    model: Model,
    fx: Fx,
    lay: Layout,
    size: Size,
}

impl Play {
    fn new(model: Model, seed: u64) -> Play {
        let (score, best) = (model.score, model.best);
        let mut fx = Fx::new(seed, score, best);
        if model.game_over {
            fx.over = Some(OVER_DUR);
        }
        Play {
            model,
            fx,
            lay: Layout::default(),
            size: Size::new(0.0, 0.0),
        }
    }

    fn new_game(&mut self, difficulty: Difficulty, seed: u64) {
        self.model.new_game(difficulty, seed);
        let best = self.fx.shown_best;
        self.fx = Fx::new(seed ^ 0x5DEE_CE66, 0, self.model.best);
        self.fx.shown_best = best.max(self.model.best as f64);
    }

    /// Where the tray draws `slot`'s piece: its top-left and block size.
    fn tray_origin(&self, slot: usize) -> (f64, f64, f64) {
        let l = self.lay;
        let (w, h) = self.model.tray[slot].map_or((1.0, 1.0), |p| {
            (p.shape().width() as f64, p.shape().height() as f64)
        });
        (
            l.bx + slot as f64 * l.slot_w + (l.slot_w - w * l.mini) / 2.0,
            l.tray_y + (l.tray_h - h * l.mini) / 2.0,
            l.mini,
        )
    }

    /// Where a held piece is headed at full size: over the finger, or on its keyboard cell
    /// raised a little off the board.
    fn held_target(&self, h: &Held) -> (f64, f64, f64) {
        let (l, cs) = (self.lay, self.lay.cell);
        if let Some((r, c)) = h.keys {
            return (l.bx + c as f64 * cs, l.by + r as f64 * cs - cs * 0.18, cs);
        }
        let (w, hh) = self.model.tray[h.slot].map_or((1.0, 1.0), |p| {
            (p.shape().width() as f64, p.shape().height() as f64)
        });
        (h.at.x - w * cs / 2.0, h.at.y - h.lift - hh * cs / 2.0, cs)
    }

    /// Where a held piece is drawn now: partway from the tray while it grows.
    fn held_geometry(&self, h: &Held) -> (f64, f64, f64) {
        let (tx, ty, ts) = self.tray_origin(h.slot);
        let (x, y, s) = self.held_target(h);
        let e = ease_out(h.grow / GROW_DUR);
        (lerp(tx, x, e), lerp(ty, y, e), lerp(ts, s, e))
    }

    /// Recompute the landing cell; true when it moved onto a new cell that fits.
    fn resnap(&mut self) -> bool {
        let Some(h) = self.fx.held else {
            return false;
        };
        let snap = match h.keys {
            Some((r, c)) => self.model.can_place(h.slot, r, c).then_some((r, c)),
            None => {
                let (x, y, cs) = self.held_target(&h);
                let col = ((x - self.lay.bx) / cs).round() as i32;
                let row = ((y - self.lay.by) / cs).round() as i32;
                self.model.can_place(h.slot, row, col).then_some((row, col))
            }
        };
        let moved = snap.is_some() && snap != h.snap;
        if let Some(held) = self.fx.held.as_mut() {
            held.snap = snap;
        }
        moved
    }

    fn slot_ready(&self, slot: usize) -> bool {
        self.model.tray[slot].is_some()
            && !self.fx.flights.iter().any(|f| f.slot == slot)
            && self.fx.deal[slot] >= DEAL_DUR * 0.5
    }

    /// Pick up the tray piece under `at`; true when one was picked up.
    fn pick(&mut self, at: Point, pointer: bool) -> bool {
        if self.model.game_over || self.fx.held.is_some() {
            return false;
        }
        let l = self.lay;
        if at.y < l.tray_y - l.cell * 0.5 || at.y > l.tray_y + l.tray_h + l.cell {
            return false;
        }
        let slot = ((at.x - l.bx) / l.slot_w).floor();
        if !(-0.25..TRAY as f64 + 0.25).contains(&slot) {
            return false;
        }
        let slot = (slot.max(0.0) as usize).min(TRAY - 1);
        if !self.slot_ready(slot) {
            return false;
        }
        self.fx.held = Some(Held {
            slot,
            at,
            lift: if pointer { 0.0 } else { LIFT_TOUCH * l.cell },
            grow: 0.0,
            snap: None,
            keys: None,
        });
        self.resnap();
        true
    }

    /// Follow the finger; true when the piece snapped onto a new cell that fits.
    fn hold_at(&mut self, at: Point) -> bool {
        match self.fx.held.as_mut() {
            Some(h) if h.keys.is_none() => h.at = at,
            _ => return false,
        }
        self.resnap()
    }

    /// Let go: place it where it snapped, or send it home.
    fn release(&mut self) -> Release {
        let Some(h) = self.fx.held.take() else {
            return Release::Nothing;
        };
        if let Some((r, c)) = h.snap
            && let Some(p) = self.model.place(h.slot, r, c)
        {
            self.celebrate(&p);
            return Release::Placed(p);
        }
        let from = self.held_geometry(&h);
        self.fx.flights.push(Flight {
            slot: h.slot,
            from,
            age: 0.0,
        });
        let in_tray = h.keys.is_none() && h.at.y >= self.lay.tray_y - self.lay.cell * 0.5;
        if in_tray {
            Release::Cancelled
        } else {
            Release::Returned
        }
    }

    /// Send a held piece back to its tray slot without placing it (a pause, a cancel, or the
    /// keyboard switching to another piece), from wherever it is drawn now.
    fn send_home(&mut self) {
        if let Some(h) = self.fx.held.take() {
            let from = self.held_geometry(&h);
            self.fx.flights.push(Flight {
                slot: h.slot,
                from,
                age: 0.0,
            });
        }
    }

    /// 1–3: pick up that piece, or drop it if it is the one already held.
    fn key_slot(&mut self, slot: usize) -> KeyOutcome {
        match self.fx.held {
            Some(h) if h.keys.is_none() => return KeyOutcome::Nothing,
            Some(h) if h.slot == slot => {
                if h.snap.is_none() {
                    return KeyOutcome::Refused;
                }
                return KeyOutcome::Released(self.release());
            }
            _ => {}
        }
        if self.model.game_over || !self.slot_ready(slot) {
            return KeyOutcome::Refused;
        }
        let Some(at) = self.model.nearest_fit(slot) else {
            return KeyOutcome::Refused;
        };
        // Switching pieces sends the previous one home first.
        self.send_home();
        let (tx, ty, _) = self.tray_origin(slot);
        self.fx.held = Some(Held {
            slot,
            at: Point::new(tx, ty),
            lift: 0.0,
            grow: 0.0,
            snap: None,
            keys: Some(at),
        });
        self.resnap();
        KeyOutcome::Lifted
    }

    fn key_move(&mut self, dr: i32, dc: i32) -> KeyOutcome {
        let Some(h) = self.fx.held else {
            return KeyOutcome::Nothing;
        };
        let (Some((r, c)), Some(piece)) = (h.keys, self.model.tray[h.slot]) else {
            return KeyOutcome::Nothing;
        };
        let (nr, nc) = (r + dr, c + dc);
        if !model::in_bounds(piece.shape(), nr, nc) {
            return KeyOutcome::Refused;
        }
        if let Some(held) = self.fx.held.as_mut() {
            held.keys = Some((nr, nc));
        }
        self.resnap();
        KeyOutcome::Moved {
            fits: self.fx.held.and_then(|h| h.snap).is_some(),
        }
    }

    /// Everything a placement sets off on screen.
    fn celebrate(&mut self, p: &Placement) {
        let l = self.lay;
        let scale = (l.side / 380.0).clamp(0.75, 1.25);
        let fx = &mut self.fx;
        for &i in &p.cells {
            if self.model.grid[i].is_some() {
                fx.squash.retain(|(c, _)| *c != i);
                fx.squash.push((i, 0.0));
            }
        }
        let n = p.cells.len().max(1) as f64;
        let cr = p.cells.iter().map(|&i| (i / N) as f64).sum::<f64>() / n;
        let cc = p.cells.iter().map(|&i| (i % N) as f64).sum::<f64>() / n;
        for (k, &(i, color)) in p.cleared.iter().enumerate() {
            let (r, c) = ((i / N) as f64, (i % N) as f64);
            let delay = ((r - cr).powi(2) + (c - cc).powi(2)).sqrt() * WAVE;
            fx.ghosts.push(Ghost {
                i,
                color,
                delay,
                age: 0.0,
                spin: if k % 2 == 0 { 1.0 } else { -1.0 },
            });
            let (x, y) = (l.bx + (c + 0.5) * l.cell, l.by + (r + 0.5) * l.cell);
            for _ in 0..3 {
                let angle = fx.rng.range(0.0, TAU);
                let speed = fx.rng.range(90.0, 260.0) * scale;
                let life = fx.rng.range(0.45, 0.85);
                fx.particles.push(Particle {
                    x,
                    y,
                    vx: angle.cos() * speed,
                    vy: angle.sin() * speed - 140.0 * scale,
                    delay: delay + FLASH_DUR,
                    life,
                    max: life,
                    color,
                    size: fx.rng.range(0.14, 0.26) * l.cell,
                    angle: fx.rng.range(0.0, TAU),
                    spin: fx.rng.range(-9.0, 9.0),
                });
            }
        }
        let tier = p.tier();
        fx.popups.push(Popup {
            text: format!("+{}", p.gain),
            x: l.bx + (cc + 0.5) * l.cell,
            y: l.by + (cr + 0.5) * l.cell,
            age: 0.0,
            size: [17.0, 20.0, 23.0, 26.0, 30.0, 34.0, 40.0][tier as usize] * scale,
            color: tier_color(tier),
        });
        if tier > 0 {
            let pick = fx.rng.below(3);
            let sub = if p.combo >= 2 {
                Some(tr("bb_combo").arg("n", p.combo as f64).format())
            } else if p.lines() >= 2 {
                Some(tr("bb_lines").arg("n", p.lines() as f64).format())
            } else {
                None
            };
            fx.banner = Some(Banner {
                text: message(tier, pick).format(),
                sub,
                tier,
                age: 0.0,
            });
            fx.shake = 0.0;
            fx.shake_amp = [0.0, 0.0, 3.5, 5.5, 7.5, 9.5, 11.0][tier as usize] * scale;
            fx.pulse = 0.0;
            fx.pulse_amp = if tier >= 4 { 0.04 } else { 0.025 };
        }
        if p.perfect {
            let w = self.size.width.max(l.side);
            for _ in 0..90 {
                fx.confetti.push(Confetti {
                    x: fx.rng.range(0.0, w),
                    y: fx.rng.range(-90.0, -10.0),
                    vx: fx.rng.range(-70.0, 70.0),
                    vy: fx.rng.range(60.0, 220.0),
                    angle: fx.rng.range(0.0, TAU),
                    spin: fx.rng.range(-7.0, 7.0),
                    color: fx.rng.below(BASE.len()) as u8,
                    w: fx.rng.range(6.0, 10.0) * scale,
                    h: fx.rng.range(9.0, 14.0) * scale,
                    life: CONFETTI_LIFE,
                });
            }
        }
        if p.refilled {
            fx.deal = [0.0, -DEAL_STAGGER, -2.0 * DEAL_STAGGER];
        }
        if p.game_over {
            fx.over = Some(0.0);
        }
    }

    /// Anything still moving.
    fn active(&self) -> bool {
        let fx = &self.fx;
        fx.held.is_some_and(|h| h.grow < GROW_DUR)
            || !fx.flights.is_empty()
            || !fx.squash.is_empty()
            || !fx.ghosts.is_empty()
            || !fx.particles.is_empty()
            || !fx.popups.is_empty()
            || fx.banner.is_some()
            || !fx.confetti.is_empty()
            || fx.shake < SHAKE_DUR
            || fx.pulse < PULSE_DUR
            || fx.deal.iter().any(|&t| t < DEAL_DUR)
            || fx.over.is_some_and(|t| t < OVER_DUR)
            || fx.shown_score != self.model.score as f64
            || fx.shown_best != self.model.best as f64
    }

    /// Advance every tween by `dt`. Returns whether this frame needs a repaint and whether
    /// the counted-up score or best changed.
    fn step(&mut self, dt: f64) -> (bool, bool) {
        let busy = self.active();
        let height = self.size.height;
        let fx = &mut self.fx;
        fx.t += dt;
        if let Some(h) = fx.held.as_mut() {
            h.grow = (h.grow + dt).min(GROW_DUR);
        }
        fx.flights.retain_mut(|f| {
            f.age += dt;
            f.age < RETURN_DUR
        });
        fx.squash.retain_mut(|(_, age)| {
            *age += dt;
            *age < SQUASH_DUR
        });
        fx.ghosts.retain_mut(|g| {
            g.age += dt;
            g.age < g.delay + FLASH_DUR + TUMBLE_DUR
        });
        fx.particles.retain_mut(|p| {
            if p.delay > 0.0 {
                p.delay -= dt;
                return true;
            }
            p.vy += PARTICLE_GRAVITY * dt;
            p.x += p.vx * dt;
            p.y += p.vy * dt;
            p.angle += p.spin * dt;
            p.life -= dt;
            p.life > 0.0
        });
        fx.popups.retain_mut(|p| {
            p.age += dt;
            p.age < POPUP_LIFE
        });
        if let Some(b) = fx.banner.as_mut() {
            b.age += dt;
            let life = if b.tier >= 6 {
                BANNER_LIFE_PERFECT
            } else {
                BANNER_LIFE
            };
            if b.age >= life {
                fx.banner = None;
            }
        }
        fx.confetti.retain_mut(|c| {
            c.vy += 380.0 * dt;
            c.vx *= 1.0 - 0.6 * dt;
            c.x += c.vx * dt;
            c.y += c.vy * dt;
            c.angle += c.spin * dt;
            c.life -= dt;
            c.life > 0.0 && c.y < height + 40.0
        });
        fx.shake = (fx.shake + dt).min(SHAKE_DUR);
        fx.pulse = (fx.pulse + dt).min(PULSE_DUR);
        for t in &mut fx.deal {
            *t = (*t + dt).min(DEAL_DUR);
        }
        if let Some(t) = fx.over.as_mut() {
            *t = (*t + dt).min(OVER_DUR);
        }
        let before = (fx.shown_score.round(), fx.shown_best.round());
        count_up(&mut fx.shown_score, self.model.score as f64, dt);
        count_up(&mut fx.shown_best, self.model.best as f64, dt);
        let hud = before != (fx.shown_score.round(), fx.shown_best.round());
        (busy, hud)
    }

    /// The gray sweep has finished and the results card may come up.
    fn over_ready(&self) -> bool {
        self.model.game_over && self.fx.over.is_some_and(|t| t >= OVER_DUR)
    }

    fn draw(&self, d: &mut Draw) {
        let l = self.lay;
        if l.side < 8.0 {
            return;
        }
        let fx = &self.fx;
        // The board shakes and pulses; the tray and the held piece stay put.
        let (sx, sy) = if fx.shake < SHAKE_DUR {
            let k = 1.0 - fx.shake / SHAKE_DUR;
            (
                fx.shake_amp * k * (fx.shake * 55.0).sin(),
                fx.shake_amp * 0.5 * k * (fx.shake * 47.0).cos(),
            )
        } else {
            (0.0, 0.0)
        };
        let pulse = if fx.pulse < PULSE_DUR {
            let t = fx.pulse / PULSE_DUR;
            1.0 + fx.pulse_amp * (t * PI).sin() * (1.0 - t)
        } else {
            1.0
        };
        let (cx, cy) = (l.bx + l.side / 2.0, l.by + l.side / 2.0);
        d.transformed(
            Affine::translate(-cx, -cy)
                .then(Affine::scale(pulse, pulse))
                .then(Affine::translate(cx + sx, cy + sy)),
            |d| self.draw_board(d),
        );
        self.draw_tray(d);
        for f in &fx.flights {
            if let Some(p) = self.model.tray[f.slot] {
                let (tx, ty, ts) = self.tray_origin(f.slot);
                let e = ease_out(f.age / RETURN_DUR);
                let (x, y, s) = (
                    lerp(f.from.0, tx, e),
                    lerp(f.from.1, ty, e),
                    lerp(f.from.2, ts, e),
                );
                for &(r, c) in p.shape().cells {
                    draw_block(d, x + c as f64 * s, y + r as f64 * s, s, p.color, 1.0, 1.0);
                }
            }
        }
        if let Some(h) = fx.held
            && let Some(p) = self.model.tray[h.slot]
        {
            let (x, y, s) = self.held_geometry(&h);
            for &(r, c) in p.shape().cells {
                d.fill(
                    Shape::RoundedRect(
                        Rect::new(
                            x + c as f64 * s + s * 0.10,
                            y + r as f64 * s + s * 0.16,
                            s * 0.9,
                            s * 0.9,
                        ),
                        s * 0.18,
                    ),
                    Color::rgba(0.0, 0.0, 0.0, 0.28),
                );
            }
            for &(r, c) in p.shape().cells {
                draw_block(d, x + c as f64 * s, y + r as f64 * s, s, p.color, 1.0, 1.0);
            }
        }
        self.draw_effects(d);
    }

    fn draw_board(&self, d: &mut Draw) {
        let (l, m, fx) = (self.lay, &self.model, &self.fx);
        let pad = l.cell * 0.14;
        let frame = Rect::new(
            l.bx - pad,
            l.by - pad,
            l.side + 2.0 * pad,
            l.side + 2.0 * pad,
        );
        d.fill(Shape::RoundedRect(frame, l.cell * 0.32), BOARD_BG);
        d.stroke(Shape::RoundedRect(frame, l.cell * 0.32), BOARD_RIM, 1.5);

        // The landing preview: the held piece's cell, color, and the lines it would complete.
        let preview = fx.held.and_then(|h| h.snap.map(|(r, c)| (h.slot, r, c)));
        let (rows, cols, color) = match preview {
            Some((s, r, c)) => {
                let (rows, cols) = m.lines_if_placed(s, r, c);
                (rows, cols, m.tray[s].map(|p| p.color))
            }
            None => (Vec::new(), Vec::new(), None),
        };
        let lit = |i: usize| rows.contains(&(i / N)) || cols.contains(&(i % N));
        let inset = l.cell * 0.05;
        for i in 0..CELLS {
            let (x, y) = (
                l.bx + (i % N) as f64 * l.cell,
                l.by + (i / N) as f64 * l.cell,
            );
            match m.grid[i] {
                // A block on a line the drop would clear takes the piece's color.
                Some(c) => {
                    let c = if lit(i) { color.unwrap_or(c) } else { c };
                    draw_block(d, x, y, l.cell, c, 1.0, fx.squash_scale(i));
                }
                None => d.fill(
                    Shape::RoundedRect(
                        Rect::new(
                            x + inset,
                            y + inset,
                            l.cell - 2.0 * inset,
                            l.cell - 2.0 * inset,
                        ),
                        l.cell * 0.16,
                    ),
                    SLOT,
                ),
            }
        }
        if let Some((s, r, c)) = preview
            && let Some(p) = m.tray[s]
        {
            for &(dr, dc) in p.shape().cells {
                let (x, y) = (
                    l.bx + (c + dc as i32) as f64 * l.cell,
                    l.by + (r + dr as i32) as f64 * l.cell,
                );
                draw_block(d, x, y, l.cell, p.color, 0.42, 1.0);
            }
            // A soft pulse over everything the drop would clear.
            let glow = 0.10 + 0.08 * (fx.t * 8.0).sin();
            for i in (0..CELLS).filter(|&i| lit(i)) {
                let (x, y) = (
                    l.bx + (i % N) as f64 * l.cell,
                    l.by + (i / N) as f64 * l.cell,
                );
                d.fill(
                    Shape::RoundedRect(
                        Rect::new(
                            x + inset,
                            y + inset,
                            l.cell - 2.0 * inset,
                            l.cell - 2.0 * inset,
                        ),
                        l.cell * 0.16,
                    ),
                    Color::rgba(1.0, 1.0, 1.0, glow),
                );
            }
        }
        // A keyboard-held piece over a spot it does not fit shows its outline in red.
        if let Some(h) = fx.held
            && h.snap.is_none()
            && let (Some((r, c)), Some(p)) = (h.keys, m.tray[h.slot])
        {
            for &(dr, dc) in p.shape().cells {
                let (x, y) = (
                    l.bx + (c + dc as i32) as f64 * l.cell,
                    l.by + (r + dr as i32) as f64 * l.cell,
                );
                d.stroke(
                    Shape::RoundedRect(
                        Rect::new(
                            x + inset,
                            y + inset,
                            l.cell - 2.0 * inset,
                            l.cell - 2.0 * inset,
                        ),
                        l.cell * 0.16,
                    ),
                    Color::rgba(1.0, 0.35, 0.35, 0.9),
                    2.0,
                );
            }
        }
        // Cleared blocks: in place until the wave reaches them, a white flash, then a tumble
        // outward inside an expanding ring.
        for g in &fx.ghosts {
            let (x, y) = (
                l.bx + (g.i % N) as f64 * l.cell,
                l.by + (g.i / N) as f64 * l.cell,
            );
            let t = g.age - g.delay;
            if t < FLASH_DUR {
                draw_block(d, x, y, l.cell, g.color, 1.0, 1.0);
                if t >= 0.0 {
                    let a = 0.9 * (1.0 - t / FLASH_DUR);
                    d.fill(
                        Shape::RoundedRect(
                            Rect::new(
                                x + inset,
                                y + inset,
                                l.cell - 2.0 * inset,
                                l.cell - 2.0 * inset,
                            ),
                            l.cell * 0.18,
                        ),
                        Color::rgba(1.0, 1.0, 1.0, a),
                    );
                }
                continue;
            }
            let e = ease_out((t - FLASH_DUR) / TUMBLE_DUR);
            let (cx, cy) = (x + l.cell / 2.0, y + l.cell / 2.0);
            let ring = l.cell * (1.0 + 1.3 * e);
            d.stroke(
                Shape::RoundedRect(
                    Rect::new(cx - ring / 2.0, cy - ring / 2.0, ring, ring),
                    ring * 0.2,
                ),
                BASE[g.color as usize % BASE.len()].with_alpha(0.8 * (1.0 - e)),
                3.0,
            );
            d.transformed(
                Affine::rotate(g.spin * 1.6 * e).then(Affine::translate(cx, cy)),
                |d| {
                    draw_block(
                        d,
                        -l.cell / 2.0,
                        -l.cell / 2.0,
                        l.cell,
                        g.color,
                        1.0 - e,
                        1.0 + 0.5 * e,
                    );
                },
            );
        }
        // Out of moves: the blocks gray out a row at a time from the bottom.
        if m.game_over {
            let t = fx.over.unwrap_or(OVER_DUR);
            for (i, _) in m.grid.iter().enumerate().filter(|(_, c)| c.is_some()) {
                let row = (i / N) as f64;
                let k = ((t - OVER_DELAY - (N as f64 - 1.0 - row) * OVER_ROW) / OVER_FADE)
                    .clamp(0.0, 1.0);
                if k > 0.0 {
                    let (x, y) = (l.bx + (i % N) as f64 * l.cell, l.by + row * l.cell);
                    d.fill(
                        Shape::RoundedRect(
                            Rect::new(
                                x + inset,
                                y + inset,
                                l.cell - 2.0 * inset,
                                l.cell - 2.0 * inset,
                            ),
                            l.cell * 0.18,
                        ),
                        DIM.with_alpha(0.62 * k),
                    );
                }
            }
        }
    }

    fn draw_tray(&self, d: &mut Draw) {
        let fx = &self.fx;
        for slot in 0..TRAY {
            let Some(p) = self.model.tray[slot] else {
                continue;
            };
            if fx.held.is_some_and(|h| h.slot == slot) || fx.flights.iter().any(|f| f.slot == slot)
            {
                continue;
            }
            let t = fx.deal[slot];
            if t < 0.0 {
                continue;
            }
            let pop = if t < DEAL_DUR {
                ease_out_back(t / DEAL_DUR)
            } else {
                1.0
            };
            // A piece that fits nowhere is dimmed: the player can see it is stuck.
            let alpha = if self.model.slot_fits(slot) || self.model.game_over {
                1.0
            } else {
                0.32
            };
            let (x, y, s) = self.tray_origin(slot);
            let (w, h) = (p.shape().width() as f64 * s, p.shape().height() as f64 * s);
            let (cx, cy) = (x + w / 2.0, y + h / 2.0);
            d.transformed(
                Affine::translate(-cx, -cy)
                    .then(Affine::scale(pop, pop))
                    .then(Affine::translate(cx, cy)),
                |d| {
                    for &(r, c) in p.shape().cells {
                        draw_block(
                            d,
                            x + c as f64 * s,
                            y + r as f64 * s,
                            s,
                            p.color,
                            alpha,
                            1.0,
                        );
                    }
                },
            );
        }
    }

    fn draw_effects(&self, d: &mut Draw) {
        let (l, fx) = (self.lay, &self.fx);
        let scale = (l.side / 380.0).clamp(0.75, 1.25);
        for p in &fx.particles {
            if p.delay > 0.0 {
                continue;
            }
            let a = (p.life / p.max).clamp(0.0, 1.0);
            let s = p.size;
            d.transformed(
                Affine::rotate(p.angle).then(Affine::translate(p.x, p.y)),
                |d| {
                    d.fill(
                        Shape::RoundedRect(Rect::new(-s / 2.0, -s / 2.0, s, s), s * 0.2),
                        BASE[p.color as usize % BASE.len()].with_alpha(a),
                    );
                },
            );
        }
        for p in &fx.popups {
            let t = p.age / POPUP_LIFE;
            let y = p.y - 70.0 * scale * ease_out(t);
            let a = if t < 0.6 { 1.0 } else { 1.0 - (t - 0.6) / 0.4 };
            let size = p.size * (0.6 + 0.4 * ease_out_back(p.age / 0.22));
            outlined_text(d, &p.text, Point::new(p.x, y), size, p.color, a, None);
        }
        if let Some(b) = &fx.banner {
            let life = if b.tier >= 6 {
                BANNER_LIFE_PERFECT
            } else {
                BANNER_LIFE
            };
            let pop = ease_out_back(b.age / 0.28);
            let fade = ((life - b.age) / 0.35).clamp(0.0, 1.0);
            let size = [0.0, 28.0, 32.0, 36.0, 42.0, 48.0, 52.0][b.tier as usize] * scale;
            let wiggle = if b.tier >= 5 {
                (1.0 - pop) * -0.14
            } else {
                0.0
            };
            let at = Point::new(l.bx + l.side / 2.0, l.by + l.side * 0.42);
            let color = tier_color(b.tier);
            d.transformed(
                Affine::scale(0.4 + 0.6 * pop, 0.4 + 0.6 * pop)
                    .then(Affine::rotate(wiggle))
                    .then(Affine::translate(at.x, at.y)),
                |d| {
                    outlined_text(d, &b.text, Point::ZERO, size, color, fade, Some(color));
                    if let Some(sub) = &b.sub {
                        outlined_text(
                            d,
                            sub,
                            Point::new(0.0, size * 0.95),
                            size * 0.55,
                            Color::rgb(1.0, 0.72, 0.30),
                            fade,
                            None,
                        );
                    }
                },
            );
        }
        for c in &fx.confetti {
            let a = (c.life / 0.6).clamp(0.0, 1.0);
            let (w, h) = (c.w, c.h);
            d.transformed(
                Affine::rotate(c.angle).then(Affine::translate(c.x, c.y)),
                |d| {
                    d.fill(
                        Shape::Rect(Rect::new(-w / 2.0, -h / 2.0, w, h)),
                        BASE[c.color as usize % BASE.len()].with_alpha(a),
                    );
                },
            );
        }
    }
}

/// Ease the HUD's counted value toward `target`: quick for big jumps, never slower than a
/// point per frame, and straight down for a reset.
fn count_up(shown: &mut f64, target: f64, dt: f64) {
    if target < *shown || (target - *shown).abs() < 0.5 {
        *shown = target;
        return;
    }
    let step = ((target - *shown) * (1.0 - (-dt * 7.0).exp())).max(60.0 * dt);
    *shown = (*shown + step).min(target);
}

/// Heavy centered text with a drop shadow and an optional glow halo, at opacity `alpha`.
fn outlined_text(
    d: &mut Draw,
    text: &str,
    at: Point,
    size: f64,
    color: Color,
    alpha: f64,
    glow: Option<Color>,
) {
    let style = |c: Color| TextStyle {
        size,
        color: c,
        anchor: TextAnchor::CENTERED,
        font: chrome::canvas_font(FontWeight::Black),
    };
    if let Some(g) = glow {
        let o = size * 0.06;
        for (dx, dy) in [(-o, 0.0), (o, 0.0), (0.0, -o), (0.0, o)] {
            d.text(
                text,
                Point::new(at.x + dx, at.y + dy),
                style(g.with_alpha(0.45 * alpha)),
            );
        }
    }
    d.text(
        text,
        Point::new(at.x + size * 0.04, at.y + size * 0.07),
        style(Color::rgba(0.0, 0.0, 0.0, 0.55 * alpha)),
    );
    d.text(text, at, style(color.with_alpha(alpha)));
}

/// The home-grid tile: a board mid-game with a line about to clear, drawn with the same
/// blocks as gameplay.
pub fn blockblast_preview() -> AnyPiece {
    const PATTERN: [&str; 8] = [
        "........", ".11.....", ".11..33.", "5....33.", "55..222.", "4444444.", "66.07..7",
        "66000.77",
    ];
    canvas(|d, sz| {
        if sz.width < 4.0 || sz.height < 4.0 {
            return;
        }
        d.fill(
            Shape::Rect(Rect::new(0.0, 0.0, sz.width, sz.height)),
            LinearGradient::new(
                UnitPoint::TOP,
                UnitPoint::BOTTOM,
                vec![(0.0, BG_TOP), (1.0, SURFACE)],
            ),
        );
        let side = sz.width.min(sz.height) * 0.86;
        let (ox, oy) = ((sz.width - side) / 2.0, (sz.height - side) / 2.0);
        let cell = side / N as f64;
        d.fill(
            Shape::RoundedRect(Rect::new(ox - 3.0, oy - 3.0, side + 6.0, side + 6.0), 8.0),
            BOARD_BG,
        );
        for (r, line) in PATTERN.iter().enumerate() {
            for (c, ch) in line.bytes().enumerate() {
                let (x, y) = (ox + c as f64 * cell, oy + r as f64 * cell);
                if ch == b'.' {
                    d.fill(
                        Shape::RoundedRect(
                            Rect::new(x + 0.6, y + 0.6, cell - 1.2, cell - 1.2),
                            cell * 0.16,
                        ),
                        SLOT,
                    );
                } else {
                    // Row 5 is one block from clearing: it wears the incoming piece's color.
                    let color = if r == 5 { 4 } else { ch - b'0' };
                    draw_block(d, x, y, cell, color, 1.0, 1.0);
                }
            }
        }
        draw_block(d, ox + 7.0 * cell, oy + 5.0 * cell, cell, 4, 0.5, 1.0);
    })
    .any()
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Overlay {
    None,
    Pause,
    GameOver,
    Difficulty,
    Settings,
    Instructions,
}

struct Ui {
    play: Rc<RefCell<Play>>,
    /// The board canvas: every edit and every animated frame.
    repaint: Trigger,
    /// The score and best labels, as the counted-up values change.
    hud: Trigger,
    overlay: Signal<Overlay>,
    /// Where the difficulty picker's Cancel returns to.
    return_to: Cell<Overlay>,
    sounds: Signal<bool>,
    vibrations: Signal<bool>,
    /// A mouse or trackpad has moved over the board: drag pieces from their middle.
    pointer_seen: Cell<bool>,
    /// The results card has been shown for the game that ended.
    over_shown: Cell<bool>,
    /// The best score when this game began, to tell a new record.
    best_before: Cell<i64>,
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
        if self.overlay.get_untracked() == Overlay::None && !self.play.borrow().model.game_over {
            self.play.borrow_mut().send_home();
            self.show(Overlay::Pause);
        }
    }
    /// New Game asks for the rules first; the picker starts the game.
    fn pick_difficulty(&self) {
        self.return_to.set(self.overlay.get_untracked());
        self.show(Overlay::Difficulty);
    }
    fn new_game(&self, difficulty: Difficulty) {
        self.play.borrow_mut().new_game(difficulty, gamekit::seed());
        gamekit::clear(SAVE_KEY);
        self.best_before.set(self.play.borrow().model.best);
        self.over_shown.set(false);
        self.return_to.set(Overlay::None);
        self.show(Overlay::None);
        self.hud.notify();
        self.cue(&cues::START);
    }
    fn record(&self) {
        gamekit::save(RECORD_KEY, &self.play.borrow().model.best);
    }
    /// The sound and haptics for a drop.
    fn landed(&self, release: Release) {
        match release {
            Release::Placed(p) => {
                match p.tier() {
                    0 if p.cells.len() >= 6 => self.cue(&PLACE_BIG),
                    0 => self.cue(&PLACE),
                    tier => {
                        // The clear's phrase rides on the knock of the piece landing.
                        chrome::sound(self.sounds.get_untracked(), &PLACE_SFX, 0.8);
                        self.cue(match tier {
                            1..=5 => &CLEARS[tier as usize - 1],
                            _ => &PERFECT_CUE,
                        });
                    }
                }
                if p.game_over {
                    self.record();
                    self.cue(&OUT_OF_MOVES_CUE);
                }
            }
            Release::Returned => self.cue(&cues::WARNING),
            Release::Cancelled => self.cue(&CANCEL),
            Release::Nothing => {}
        }
    }
    /// The gray sweep finished: the results card, and a fanfare for a new record.
    fn game_over(&self) {
        self.record();
        let best = self.play.borrow().model.best;
        let score = self.play.borrow().model.score;
        if score > 0 && score >= best && score > self.best_before.get() {
            self.cue(&RECORD);
        }
        self.show(Overlay::GameOver);
    }
}

/// The Block Blast screen.
pub fn blockblast_page() -> AnyPiece {
    let settings = gamekit::restore::<chrome::GameSettings>(SETTINGS_KEY).unwrap_or_default();
    let seed = gamekit::seed();
    let mut model = Model::new(seed, Difficulty::Normal);
    if let Some(s) = gamekit::restore::<model::SaveState>(SAVE_KEY)
        && !model.apply_save(s)
    {
        gamekit::clear(SAVE_KEY);
    }
    model.best = model
        .best
        .max(gamekit::restore::<i64>(RECORD_KEY).unwrap_or(0));
    let restored_over = model.game_over;
    let best = model.best;
    let ui = Rc::new(Ui {
        play: Rc::new(RefCell::new(Play::new(model, seed ^ 0xB10C))),
        repaint: Trigger::new(),
        hud: Trigger::new(),
        overlay: Signal::new(Overlay::None),
        return_to: Cell::new(Overlay::None),
        sounds: Signal::new(settings.sounds),
        vibrations: Signal::new(settings.vibrations),
        pointer_seen: Cell::new(false),
        over_shown: Cell::new(restored_over),
        best_before: Cell::new(best),
    });
    gamekit::autosave(SAVE_KEY, {
        let play = ui.play.clone();
        move || play.borrow().model.save_state()
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
    } else if restored_over {
        ui.show(Overlay::GameOver);
    }
    gamekit::on_background(SAVE_KEY, {
        let ui = ui.clone();
        move || ui.pause()
    });

    let backdrop = canvas(|d, sz| {
        d.fill(
            Shape::Rect(Rect::new(0.0, 0.0, sz.width, sz.height)),
            LinearGradient::new(
                UnitPoint::TOP,
                UnitPoint::BOTTOM,
                vec![(0.0, BG_TOP), (1.0, SURFACE)],
            ),
        );
    })
    .grow();

    let board = {
        let (du, dr, hu, ku) = (ui.clone(), ui.clone(), ui.clone(), ui.clone());
        canvas(move |d, sz| {
            du.repaint.track();
            {
                let mut p = du.play.borrow_mut();
                p.lay = layout(sz);
                p.size = sz;
            }
            du.play.borrow().draw(d);
        })
        .on_drag(move |dg| {
            if dr.overlay.get_untracked() != Overlay::None {
                return;
            }
            let pointer = dr.pointer_seen.get();
            match dg.phase {
                DragPhase::Began => {
                    let picked = dr.play.borrow_mut().pick(dg.location, pointer);
                    if picked {
                        dr.cue(&LIFT);
                    }
                }
                DragPhase::Ended => {
                    let release = dr.play.borrow_mut().release();
                    dr.landed(release);
                }
                _ => {
                    let snapped = dr.play.borrow_mut().hold_at(dg.location);
                    if snapped {
                        dr.cue(&cues::TICK);
                    }
                }
            }
            dr.repaint.notify();
        })
        .on_hover(move |_| hu.pointer_seen.set(true))
        .on_key(move |k| {
            if ku.overlay.get_untracked() != Overlay::None {
                return;
            }
            let outcome = {
                let mut p = ku.play.borrow_mut();
                match k.key.as_str() {
                    "1" => p.key_slot(0),
                    "2" => p.key_slot(1),
                    "3" => p.key_slot(2),
                    "ArrowLeft" => p.key_move(0, -1),
                    "ArrowRight" => p.key_move(0, 1),
                    "ArrowUp" => p.key_move(-1, 0),
                    "ArrowDown" => p.key_move(1, 0),
                    "Delete" | "Backspace" if p.fx.held.is_some() => {
                        p.send_home();
                        KeyOutcome::Released(Release::Cancelled)
                    }
                    _ => KeyOutcome::Nothing,
                }
            };
            match outcome {
                KeyOutcome::Lifted => ku.cue(&LIFT),
                KeyOutcome::Moved { fits: true } => ku.cue(&cues::TICK),
                KeyOutcome::Moved { fits: false } | KeyOutcome::Nothing => {}
                KeyOutcome::Refused => ku.cue(&cues::WARNING),
                KeyOutcome::Released(r) => ku.landed(r),
            }
            ku.repaint.notify();
        })
        .a11y(|a| a.label(tr("bb_board_a11y").format()))
        .id("bb-canvas")
        .grow()
    };

    // Mounted only while the game is live, so the display link goes idle behind a card.
    let clock = {
        let (cu, bu) = (ui.clone(), ui.clone());
        when(
            move || cu.overlay.get() == Overlay::None,
            move || blockblast_clock(bu.clone()),
        )
    };

    zstack((
        backdrop,
        column((hud(ui.clone()), board)).spacing(0.0).grow(),
        overlays(ui),
        clock,
    ))
    .any()
}

/// Score, title, best and the pause button; the leading gutter clears the cover's close button.
fn hud(ui: Rc<Ui>) -> impl Piece {
    let (su, bu) = (ui.clone(), ui.clone());
    let score = column((
        label(tr("gk_score"))
            .font(Font::Caption)
            .weight(FontWeight::Bold)
            .color(chrome::TEXT_DIM),
        label(move || {
            su.hud.track();
            (su.play.borrow().fx.shown_score.round() as i64).to_string()
        })
        .font(Font::Title2)
        .bold()
        .tabular()
        .color(Color::WHITE)
        .id("bb-score")
        // Room for a six-digit score from the first layout, so a growing value never truncates.
        .min_width(88.0),
    ))
    .spacing(0.0)
    .align(HAlign::Leading);
    let best = column((
        label(tr("gk_best"))
            .font(Font::Caption)
            .weight(FontWeight::Bold)
            .color(chrome::TEXT_DIM),
        label(move || {
            bu.hud.track();
            (bu.play.borrow().fx.shown_best.round() as i64).to_string()
        })
        .font(Font::Title2)
        .bold()
        .tabular()
        .color(chrome::GOLD)
        .align(TextAlign::Trailing)
        .id("bb-best")
        // Room for a six-digit best from the first layout, so a growing value never truncates.
        .min_width(88.0),
    ))
    .spacing(0.0)
    .align(HAlign::Trailing);
    let pause = chrome::pause_button(tr("gk_pause"), "bb-pause", move || {
        ui.pause();
        ui.cue(&cues::SELECT);
    });
    row((
        spacer().width(52.0),
        score,
        // Narrows, then steps aside, on a phone too narrow for it beside two six-digit scores.
        chrome::fitted_title(tr("nav_blockblast"), 17.0, FontWeight::Heavy, chrome::TEXT).grow_w(),
        best,
        pause,
    ))
    .spacing(8.0)
    .align(VAlign::Center)
    .padding(Insets {
        top: 4.0,
        leading: 0.0,
        bottom: 0.0,
        trailing: 6.0,
    })
}

/// The frame consumer: every tween and effect, the HUD count-up, and the results card once the
/// gray sweep has run.
fn blockblast_clock(ui: Rc<Ui>) -> impl Piece {
    frame_clock(move |dt| {
        let (busy, hud, over) = {
            let mut p = ui.play.borrow_mut();
            let (busy, hud) = p.step(dt.as_secs_f64());
            (busy, hud, p.over_ready())
        };
        if hud {
            ui.hud.notify();
        }
        if busy {
            ui.repaint.notify();
        }
        if over && !ui.over_shown.replace(true) {
            ui.game_over();
        }
    })
}

fn overlays(ui: Rc<Ui>) -> impl Piece {
    let scrim = {
        let u = ui.clone();
        when(move || u.overlay.get() != Overlay::None, chrome::scrim)
    };
    let (p, g, d, s, i) = (ui.clone(), ui.clone(), ui.clone(), ui.clone(), ui.clone());
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
            chrome::menu_button(tr("gk_resume"), chrome::GREEN, "bb-resume", move || {
                u1.show(Overlay::None)
            }),
            chrome::menu_button(tr("gk_new_game"), chrome::BLUE, "bb-new-game", move || {
                u2.pick_difficulty()
            }),
            chrome::menu_button(tr("gk_settings"), chrome::SLATE, "bb-settings", move || {
                u3.show(Overlay::Settings)
            }),
            chrome::menu_button(
                tr("gk_instructions"),
                chrome::INDIGO,
                "bb-instructions",
                move || u4.show(Overlay::Instructions),
            ),
            chrome::menu_button(tr("gk_quit"), chrome::RED, "bb-quit", || {
                nav_back();
            }),
        ))
        .spacing(14.0)
        .align(HAlign::Center),
    )
    .id("bb-pause-menu")
    .any()
}

fn game_over_card(ui: Rc<Ui>) -> AnyPiece {
    let (score, best, difficulty) = {
        let p = ui.play.borrow();
        (p.model.score, p.model.best, p.model.difficulty)
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
            label(tr("bb_no_moves")).color(chrome::TEXT_DIM),
            chrome::stat(
                tr("gk_score"),
                score.to_string(),
                Font::LargeTitle,
                chrome::GOLD,
                "bb-final-score",
            ),
            chrome::stat(
                tr("gk_best"),
                best.to_string(),
                Font::Title3,
                Color::WHITE,
                "bb-final-best",
            ),
            label(difficulty_label(difficulty))
                .font(Font::Subheadline)
                .bold()
                .color(accent(difficulty)),
            record,
            chrome::menu_button(
                tr("gk_play_again"),
                chrome::BLUE,
                "bb-play-again",
                move || u.pick_difficulty(),
            ),
            chrome::menu_button(tr("gk_quit"), chrome::RED, "bb-quit", || {
                nav_back();
            }),
        ))
        .spacing(14.0)
        .align(HAlign::Center),
    )
    .id("bb-game-over")
    .any()
}

fn difficulty_picker(ui: Rc<Ui>) -> AnyPiece {
    let current = ui.play.borrow().model.difficulty;
    let mut cards = Vec::new();
    for d in DIFFICULTIES {
        let u = ui.clone();
        let tint = accent(d);
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
                    label(difficulty_label(d))
                        .font(Font::Title3)
                        .bold()
                        .color(Color::WHITE),
                    label(difficulty_detail(d))
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
            label(tr("bb_choose_difficulty"))
                .font(Font::Title2)
                .bold()
                .color(Color::WHITE),
            column(PieceVec(cards)).spacing(12.0),
            button(tr("gk_cancel"))
                .action(move || {
                    let back = u.return_to.replace(Overlay::None);
                    u.show(back);
                })
                .id("bb-cancel"),
        ))
        .spacing(16.0)
        .align(HAlign::Center),
    )
    .id("bb-difficulty-picker")
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
                        {
                            let mut p = u.play.borrow_mut();
                            p.model.best = p.model.score;
                            p.fx.shown_best = p.model.score as f64;
                        }
                        u.best_before.set(0);
                        gamekit::clear(RECORD_KEY);
                        u.hud.notify();
                    }
                });
            })
            .id("bb-reset-high-score")
    };
    let done = ui.clone();
    chrome::card(
        column((
            label(tr("gk_settings"))
                .font(Font::Title2)
                .bold()
                .color(Color::WHITE),
            chrome::section_heading(tr("nav_blockblast")),
            chrome::setting_row(tr("gk_sounds"), toggle(ui.sounds).id("bb-sounds").any()),
            chrome::setting_row(
                tr("gk_vibrations"),
                toggle(ui.vibrations).id("bb-vibrations").any(),
            ),
            chrome::section_heading(tr("gk_data")),
            reset,
            button(tr("gk_done"))
                .prominent()
                .action(move || done.show(Overlay::Pause))
                .id("bb-done"),
        ))
        .spacing(12.0)
        .align(HAlign::Center),
    )
    .id("bb-settings-card")
    .any()
}

fn instructions_card(ui: Rc<Ui>) -> AnyPiece {
    let live = {
        let p = ui.play.borrow();
        p.model.score > 0 && !p.model.game_over
    };
    chrome::instructions_card(
        tr("nav_blockblast"),
        vec![
            Help::Para(tr("bb_help_intro")),
            Help::Heading(tr("bb_help_play")),
            Help::Para(tr("bb_help_play_1")),
            Help::Para(tr("bb_help_play_2")),
            Help::Para(tr("bb_help_play_3")),
            Help::Heading(tr("bb_help_score")),
            Help::Para(tr("bb_help_score_1")),
            Help::Para(tr("bb_help_score_2")),
            Help::Para(tr("bb_help_score_3")),
            Help::Heading(tr("bb_help_difficulty")),
            Help::Para(tr("bb_help_difficulty_1")),
            Help::Heading(tr("gk_game_over_heading")),
            Help::Para(tr("bb_help_over_1")),
        ],
        "bb-help-done",
        move || ui.show(if live { Overlay::Pause } else { Overlay::None }),
    )
    .id("bb-instructions-card")
    .any()
}

#[cfg(test)]
mod tests {
    use super::*;
    use model::{Piece, SHAPES};

    fn play_with(ids: [&str; 3]) -> Play {
        let mut m = Model::new(5, Difficulty::Normal);
        m.grid = [None; CELLS];
        m.tray = ids.map(|id| {
            Some(Piece {
                shape: SHAPES.iter().position(|s| s.id == id).unwrap(),
                color: 1,
            })
        });
        let mut p = Play::new(m, 9);
        p.lay = layout(Size::new(400.0, 700.0));
        p.size = Size::new(400.0, 700.0);
        p.fx.deal = [DEAL_DUR; TRAY];
        p
    }

    fn settle(p: &mut Play) {
        for _ in 0..600 {
            p.step(1.0 / 60.0);
        }
        assert!(!p.active(), "every effect ends");
    }

    #[test]
    fn a_finger_drag_snaps_to_the_cell_under_the_lifted_piece_and_places() {
        let mut p = play_with(["sq2", "dot", "dot"]);
        let l = p.lay;
        let (tx, ty, s) = p.tray_origin(0);
        assert!(
            p.pick(Point::new(tx + s, ty + s), false),
            "the tray piece picks up"
        );
        // Aim the lifted piece's top-left at cell (2, 3): its center rides LIFT above the finger.
        let target = Point::new(
            l.bx + 3.0 * l.cell + l.cell,
            l.by + 2.0 * l.cell + l.cell + LIFT_TOUCH * l.cell,
        );
        assert!(p.hold_at(target), "snapping onto a fitting cell reports it");
        assert_eq!(p.fx.held.unwrap().snap, Some((2, 3)));
        let Release::Placed(pl) = p.release() else {
            panic!("the drop places");
        };
        assert_eq!(
            pl.cells[0],
            model::idx(2, 3),
            "the square's top-left lands on (2, 3)"
        );
        assert_eq!(p.model.score, 40);
        settle(&mut p);
    }

    #[test]
    fn a_drop_off_the_board_flies_home_and_changes_nothing() {
        let mut p = play_with(["h5", "dot", "dot"]);
        let (tx, ty, s) = p.tray_origin(0);
        assert!(p.pick(Point::new(tx + s, ty + s / 2.0), false));
        p.hold_at(Point::new(5.0, 5.0));
        assert!(matches!(p.release(), Release::Returned));
        assert_eq!(p.model.score, 0);
        assert!(p.model.tray[0].is_some(), "the piece stays in the tray");
        settle(&mut p);
        assert!(p.fx.flights.is_empty());
    }

    #[test]
    fn keys_lift_move_and_drop_the_same_piece() {
        let mut p = play_with(["dot", "h2", "dot"]);
        assert!(matches!(p.key_slot(1), KeyOutcome::Lifted));
        let start = p.fx.held.unwrap().keys.unwrap();
        assert!(matches!(p.key_move(0, 1), KeyOutcome::Moved { fits: true }));
        assert_eq!(p.fx.held.unwrap().keys, Some((start.0, start.1 + 1)));
        let KeyOutcome::Released(Release::Placed(pl)) = p.key_slot(1) else {
            panic!("pressing the same digit drops it");
        };
        assert_eq!(
            pl.cells[0],
            model::idx(start.0 as usize, start.1 as usize + 1),
            "it lands where the arrow moved it"
        );
        // Walking off the board is refused rather than clamped silently.
        assert!(matches!(p.key_slot(0), KeyOutcome::Lifted));
        for _ in 0..N {
            p.key_move(0, -1);
        }
        assert!(matches!(p.key_move(0, -1), KeyOutcome::Refused));
    }

    #[test]
    fn a_clear_runs_its_effects_to_completion() {
        let mut p = play_with(["dot", "dot", "dot"]);
        for c in 1..N {
            p.model.grid[model::idx(0, c)] = Some(2);
        }
        p.model.grid[model::idx(5, 5)] = Some(2);
        assert!(matches!(p.key_slot(0), KeyOutcome::Lifted));
        let (r, c) = p.fx.held.unwrap().keys.unwrap();
        p.key_move(-r, -c);
        let KeyOutcome::Released(Release::Placed(pl)) = p.key_slot(0) else {
            panic!("the dot drops at (0, 0)");
        };
        assert_eq!(pl.lines(), 1);
        assert_eq!(p.fx.ghosts.len(), N);
        assert!(p.fx.banner.is_some(), "a clear gets a call-out");
        settle(&mut p);
        assert_eq!(p.fx.shown_score, p.model.score as f64, "the HUD caught up");
    }

    #[test]
    fn the_scripted_seed_clears_a_line_in_four_keyboard_placements() {
        // dayscript/blockblast.yaml and games.yaml start a Normal game under DAY_GAMES_SEED=15
        // and play these placements from the keyboard: their arrow presses assume these start
        // cells, and their assertions these scores.
        let mut p = Play::new(Model::new(15, Difficulty::Normal), 1);
        p.lay = layout(Size::new(400.0, 700.0));
        p.size = Size::new(400.0, 700.0);
        let mut seen = Vec::new();
        for (slot, start, target) in SCRIPTED {
            // The tray's deal animation settles before a key can pick a piece up.
            p.step(0.5);
            assert!(matches!(p.key_slot(slot), KeyOutcome::Lifted));
            assert_eq!(
                p.fx.held.unwrap().keys,
                Some(start),
                "slot {slot} lifts where the scripts assume"
            );
            let (dr, dc) = (target.0 - start.0, target.1 - start.1);
            assert!(matches!(
                p.key_move(dr, dc),
                KeyOutcome::Moved { fits: true }
            ));
            let KeyOutcome::Released(Release::Placed(pl)) = p.key_slot(slot) else {
                panic!("slot {slot} drops at {target:?}");
            };
            seen.push((p.model.score, pl.lines()));
        }
        assert_eq!(seen, vec![(60, 0), (100, 0), (110, 0), (250, 1)]);
    }

    /// A board cell as (row, col).
    type At = (i32, i32);

    /// The walkthroughs' placements: tray slot, where the keyboard lifts it, where it lands.
    const SCRIPTED: [(usize, At, At); 4] = [
        (2, (3, 2), (0, 0)),
        (0, (3, 2), (0, 3)),
        (1, (3, 3), (0, 5)),
        (1, (2, 3), (0, 6)),
    ];
}
