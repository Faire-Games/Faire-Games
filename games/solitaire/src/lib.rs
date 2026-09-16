//! Solitaire: Klondike, dealt winnable. Two canvases draw the table (docs/canvas.md): the lower
//! one holds the cards at rest and re-records only when something changes; the upper one takes
//! every touch, click and key and draws whatever moves, stepped on Day's frame clock.
//!
//! Every card knows where it rests. When a move changes that, the card flies from wherever it is
//! drawn now, flipping on the way if it turns over, so a deal, a draw, a drop, an undo and the
//! final run home all animate the same way. A picked-up run lifts and tilts with the drag, a
//! legal target lights up under it, and a drop that is not legal flies back. Cards reaching a
//! foundation throw sparks and a ring, a completed suit rains confetti, and a win sends every
//! card bouncing off the table the way the classic game did. Taps send a card to its best spot;
//! on a keyboard, 1–7 pick a column, 8 the waste, 9 sends a card home, 0 turns the stock, and
//! the arrows change the pick. The rules and the solver behind "winnable deals only" live in
//! model.rs.

use std::cell::{Cell, RefCell};
use std::f64::consts::{PI, TAU};
use std::rc::Rc;

use day_fluent::tr;
use day_geometry::Affine;
use day_part_haptics::Haptic;
use day_pieces::prelude::*;
use gamekit::chrome::cues::{self, with};
use gamekit::chrome::{self, Cue, Feedback, Help, Pattern, Sfx, sfx};
use serde::{Deserialize, Serialize};

mod model;
use model::{
    COLS, Card, DRAW_MODES, DealSearch, DrawMode, HINT_LIMITS, Model, Move, Outcome, Pile, Solver,
    Table, Verdict,
};

/// The prefs keys this game persists under (gamekit; bump the game key on a schema change).
const SAVE_KEY: &str = "solitaire.v1";
const STATS_KEY: &str = "solitaire.stats";
const SETTINGS_KEY: &str = "solitaire.settings";

/// The game's cover surface color (edge-to-edge behind the safe area): the felt's edge.
pub const SURFACE: Color = Color::rgb(0.03, 0.22, 0.14);
const FELT: Color = Color::rgb(0.11, 0.46, 0.29);
const FACE: Color = Color::rgb(1.0, 0.99, 0.96);
const EDGE: Color = Color::rgba(0.0, 0.0, 0.0, 0.24);
const RED_INK: Color = Color::rgb(0.82, 0.13, 0.17);
const BLACK_INK: Color = Color::rgb(0.10, 0.11, 0.16);
const BACK_TOP: Color = Color::rgb(0.21, 0.35, 0.82);
const BACK_BOTTOM: Color = Color::rgb(0.10, 0.16, 0.50);
const SLOT: Color = Color::rgba(0.0, 0.0, 0.0, 0.16);
const SLOT_LINE: Color = Color::rgba(1.0, 1.0, 1.0, 0.26);
const SELECT: Color = Color::rgb(0.40, 0.86, 1.0);
const HINT_GLOW: Color = Color::rgb(1.0, 0.93, 0.45);

/// A card's height over its width: poker size.
const ASPECT: f64 = 1.4;
/// The gap between columns, in card widths.
const GAP: f64 = 0.12;
/// Cards never grow past this width on a large window.
const MAX_CW: f64 = 124.0;
/// How far each card in a column shows below the one it covers, face down and face up, in card
/// heights, and how far a crowded column may squeeze them.
const DOWN: f64 = 0.13;
const UP: f64 = 0.28;
const MIN_DOWN: f64 = 0.05;
const MIN_UP: f64 = 0.17;
/// Draw three fans the top of the waste this far apart, in card widths (heights on a side rail).
const FAN3: f64 = 0.30;
/// How far above a finger a dragged run rides, in card heights. A mouse carries it as grabbed.
const LIFT_TOUCH: f64 = 0.22;

const FLY_MIN: f64 = 0.17;
const FLY_MAX: f64 = 0.42;
const DEAL_STAGGER: f64 = 0.045;
const SHAKE_DUR: f64 = 0.36;
const POPUP_LIFE: f64 = 1.1;
const BANNER_LIFE: f64 = 1.7;
const CONFETTI_LIFE: f64 = 2.8;
const RING_LIFE: f64 = 0.55;
const HINT_LIFE: f64 = 3.2;
/// The shuffle plays at least this long, even when a winnable deal turns up at once.
const MIN_SHUFFLE: f64 = 0.8;
/// The pause before the cards start flying home by themselves, and the beat between them.
const FINISH_FIRST: f64 = 0.35;
const FINISH_STEP: f64 = 0.085;
/// The win's bouncing cards leave the foundations this far apart.
const LAUNCH_EVERY: f64 = 0.085;
const TRAIL_MAX: usize = 200;
const STUCK_DELAY: f64 = 0.6;
/// Solver positions a frame while shuffling or looking for a hint.
const SEARCH_BUDGET: u64 = 6_000;

// Haptic phrases (gamekit::chrome's vocabulary, one style per beat).
const HOME: Pattern = &[(0, Haptic::Medium), (70, Haptic::Light)];
/// Timed to the middle of a card's flip.
const REVEAL: Pattern = &[(150, Haptic::Light)];
const EMPTIED: Pattern = &[(120, Haptic::Light), (200, Haptic::Light)];
const RECYCLE: Pattern = &[
    (0, Haptic::Light),
    (60, Haptic::Light),
    (120, Haptic::Medium),
];
const SHUFFLE: Pattern = &[
    (0, Haptic::Selection),
    (70, Haptic::Selection),
    (140, Haptic::Selection),
    (210, Haptic::Selection),
    (280, Haptic::Selection),
    (350, Haptic::Light),
];
/// A tick per few cards of the deal, landing with the last column.
const DEAL: Pattern = &[
    (0, Haptic::Light),
    (90, Haptic::Light),
    (180, Haptic::Light),
    (270, Haptic::Light),
    (360, Haptic::Light),
    (450, Haptic::Light),
    (540, Haptic::Light),
    (630, Haptic::Light),
    (720, Haptic::Light),
    (810, Haptic::Light),
    (900, Haptic::Light),
    (990, Haptic::Light),
    (1080, Haptic::Light),
    (1260, Haptic::Medium),
];

// Sounds, each with the haptic it plays beside (gamekit::chrome::Cue).
static SHUFFLE_CUE: Cue = with("sounds/solitaire/shuffle.wav", SHUFFLE);
static DRAW: Cue = with("sounds/solitaire/draw.wav", cues::TICK_BEAT);
static RECYCLE_CUE: Cue = with("sounds/solitaire/recycle.wav", RECYCLE);
/// A card taken up by a drag.
static PICKUP: Cue = with("sounds/solitaire/pickup.wav", cues::LIGHT_BEAT);
/// A card taken up by a tap, to be put down by the next one.
static PICK: Cue = with("sounds/solitaire/pickup.wav", cues::TICK_BEAT);
static DROP: Cue = with("sounds/solitaire/drop.wav", cues::LIGHT_BEAT);
/// Timed, like its tick, to the middle of the card's turn.
static FLIP: Cue = Cue {
    sound: Some(sfx("sounds/solitaire/flip.wav")),
    sound_at: 150,
    volume: 1.0,
    haptic: REVEAL,
};
static EMPTIED_CUE: Cue = Cue {
    sound: None,
    sound_at: 0,
    volume: 1.0,
    haptic: EMPTIED,
};
static HOME_CUE: Cue = with("sounds/solitaire/home.wav", HOME);
static SUIT: Cue = with("sounds/solitaire/suit.wav", chrome::CELEBRATE);
static UNDO: Cue = with("sounds/solitaire/undo.wav", cues::LIGHT_BEAT);
static WIN: Cue = with("sounds/solitaire/win.wav", chrome::BIG_CELEBRATE);
/// The deal's card slides, one every other beat of its phrase, taken in turn.
static DEALS: [Sfx; 4] = [
    sfx("sounds/solitaire/deal_1.wav"),
    sfx("sounds/solitaire/deal_2.wav"),
    sfx("sounds/solitaire/deal_3.wav"),
    sfx("sounds/solitaire/deal_4.wav"),
];
const DEAL_SLIDE_EVERY: u32 = 180;
/// The finishing run's chips, taken in turn so a run of them never repeats one.
static FINISHES: [Sfx; 3] = [
    sfx("sounds/solitaire/finish_1.wav"),
    sfx("sounds/solitaire/finish_2.wav"),
    sfx("sounds/solitaire/finish_3.wav"),
];
/// A winning card landing on the felt, kept quiet under the fanfare.
static BOUNCE: Sfx = sfx("sounds/solitaire/bounce.wav");
const BOUNCE_VOLUME: f32 = 0.35;

/// Every clip this game plays besides the shared ones (gamekit preloads both).
pub const SOUNDS: &[Sfx] = &[
    sfx("sounds/solitaire/shuffle.wav"),
    sfx("sounds/solitaire/deal_1.wav"),
    sfx("sounds/solitaire/deal_2.wav"),
    sfx("sounds/solitaire/deal_3.wav"),
    sfx("sounds/solitaire/deal_4.wav"),
    sfx("sounds/solitaire/draw.wav"),
    sfx("sounds/solitaire/recycle.wav"),
    sfx("sounds/solitaire/pickup.wav"),
    sfx("sounds/solitaire/drop.wav"),
    sfx("sounds/solitaire/flip.wav"),
    sfx("sounds/solitaire/home.wav"),
    sfx("sounds/solitaire/finish_1.wav"),
    sfx("sounds/solitaire/finish_2.wav"),
    sfx("sounds/solitaire/finish_3.wav"),
    sfx("sounds/solitaire/suit.wav"),
    sfx("sounds/solitaire/win.wav"),
    sfx("sounds/solitaire/bounce.wav"),
    sfx("sounds/solitaire/undo.wav"),
];

fn ease_out(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    1.0 - (1.0 - t).powi(3)
}

fn ease_in_out(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    if t < 0.5 {
        4.0 * t * t * t
    } else {
        1.0 - (-2.0 * t + 2.0).powi(3) / 2.0
    }
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

fn lerp_rect(a: Rect, b: Rect, t: f64) -> Rect {
    Rect::new(
        lerp(a.origin.x, b.origin.x, t),
        lerp(a.origin.y, b.origin.y, t),
        lerp(a.size.width, b.size.width, t),
        lerp(a.size.height, b.size.height, t),
    )
}

fn center(r: Rect) -> Point {
    Point::new(
        r.origin.x + r.size.width / 2.0,
        r.origin.y + r.size.height / 2.0,
    )
}

fn contains(r: Rect, p: Point, slop: f64) -> bool {
    p.x >= r.origin.x - slop
        && p.x <= r.origin.x + r.size.width + slop
        && p.y >= r.origin.y - slop
        && p.y <= r.origin.y + r.size.height + slop
}

fn overlap(a: Rect, b: Rect) -> f64 {
    let w = (a.origin.x + a.size.width).min(b.origin.x + b.size.width) - a.origin.x.max(b.origin.x);
    let h =
        (a.origin.y + a.size.height).min(b.origin.y + b.size.height) - a.origin.y.max(b.origin.y);
    w.max(0.0) * h.max(0.0)
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
        (self.next() % n.max(1) as u64) as usize
    }
}

fn ink(card: Card) -> Color {
    if card.red() { RED_INK } else { BLACK_INK }
}

fn rank_label(rank: u8) -> &'static str {
    const LABELS: [&str; 13] = [
        "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K",
    ];
    LABELS[(rank.clamp(1, 13) - 1) as usize]
}

/// A suit's pip, `s` points tall, centered at `c`. Vector paths rather than text glyphs, so the
/// suits look the same on every platform's fonts.
fn draw_suit(d: &mut Draw, suit: u8, c: Point, s: f64, color: Color) {
    let p = |x: f64, y: f64| Point::new(c.x + x * s, c.y + y * s);
    match suit {
        // Hearts.
        1 => d.fill(
            PathBuilder::new()
                .move_to(p(0.0, 0.46))
                .cubic_to(p(-0.12, 0.34), p(-0.5, 0.08), p(-0.5, -0.16))
                .cubic_to(p(-0.5, -0.40), p(-0.22, -0.52), p(0.0, -0.30))
                .cubic_to(p(0.22, -0.52), p(0.5, -0.40), p(0.5, -0.16))
                .cubic_to(p(0.5, 0.08), p(0.12, 0.34), p(0.0, 0.46))
                .close()
                .build(),
            color,
        ),
        // Diamonds.
        3 => d.fill(
            Shape::Polygon(vec![p(0.0, -0.5), p(0.38, 0.0), p(0.0, 0.5), p(-0.38, 0.0)]),
            color,
        ),
        // Spades.
        0 => d.fill(
            PathBuilder::new()
                .move_to(p(0.0, -0.50))
                .cubic_to(p(0.14, -0.34), p(0.50, -0.14), p(0.50, 0.10))
                .cubic_to(p(0.50, 0.32), p(0.24, 0.40), p(0.06, 0.26))
                .line_to(p(0.15, 0.50))
                .line_to(p(-0.15, 0.50))
                .line_to(p(-0.06, 0.26))
                .cubic_to(p(-0.24, 0.40), p(-0.50, 0.32), p(-0.50, 0.10))
                .cubic_to(p(-0.50, -0.14), p(-0.14, -0.34), p(0.0, -0.50))
                .close()
                .build(),
            color,
        ),
        // Clubs: three leaves and a stem, filled separately so no winding rule can hollow them.
        _ => {
            d.fill(
                PathBuilder::new()
                    .circle(p(0.0, -0.24), 0.22 * s)
                    .circle(p(-0.24, 0.06), 0.22 * s)
                    .circle(p(0.24, 0.06), 0.22 * s)
                    .circle(p(0.0, 0.02), 0.12 * s)
                    .build(),
                color,
            );
            d.fill(
                Shape::Polygon(vec![p(0.0, 0.0), p(0.14, 0.50), p(-0.14, 0.50)]),
                color,
            );
        }
    }
}

/// A card face in `r` at opacity `alpha`: the rank and a small pip along the top (the strip a
/// fanned column shows), a large pip below, and a framed letter on the court cards.
fn draw_face(d: &mut Draw, card: Card, r: Rect, alpha: f64) {
    let (x, y, w, h) = (r.origin.x, r.origin.y, r.size.width, r.size.height);
    let radius = w * 0.09;
    let color = ink(card).with_alpha(alpha);
    d.fill(Shape::RoundedRect(r, radius), FACE.with_alpha(alpha));
    d.stroke(Shape::RoundedRect(r, radius), EDGE.with_alpha(alpha), 1.0);
    let rank = card.rank();
    d.text(
        rank_label(rank),
        Point::new(x + w * 0.07, y + w * 0.03),
        TextStyle {
            size: w * if rank == 10 { 0.31 } else { 0.35 },
            color,
            anchor: TextAnchor::LEADING,
            font: chrome::canvas_font(FontWeight::Bold),
        },
    );
    draw_suit(
        d,
        card.suit(),
        Point::new(x + w * 0.79, y + w * 0.21),
        w * 0.25,
        color,
    );
    match rank {
        1 => draw_suit(
            d,
            card.suit(),
            Point::new(x + w / 2.0, y + h * 0.60),
            w * 0.56,
            color,
        ),
        11..=13 => {
            let panel = Rect::new(x + w * 0.14, y + h * 0.36, w * 0.72, h * 0.55);
            let tint = if card.red() {
                Color::rgba(0.82, 0.13, 0.17, 0.10 * alpha)
            } else {
                Color::rgba(0.15, 0.25, 0.60, 0.11 * alpha)
            };
            d.fill(Shape::RoundedRect(panel, w * 0.06), tint);
            d.stroke(
                Shape::RoundedRect(panel, w * 0.06),
                color.with_alpha(0.35 * alpha),
                1.0,
            );
            let c = center(panel);
            d.text(
                rank_label(rank),
                Point::new(c.x, c.y - w * 0.05),
                TextStyle {
                    size: w * 0.40,
                    color,
                    anchor: TextAnchor::CENTERED,
                    font: chrome::canvas_font(FontWeight::Black),
                },
            );
            draw_suit(
                d,
                card.suit(),
                Point::new(c.x, panel.origin.y + panel.size.height - w * 0.13),
                w * 0.16,
                color,
            );
        }
        _ => draw_suit(
            d,
            card.suit(),
            Point::new(x + w / 2.0, y + h * 0.61),
            w * 0.42,
            color,
        ),
    }
}

/// The win trail's copy of a face: the card and its corner only, since every bouncing card
/// leaves hundreds of these behind it and only the edges of most show.
fn draw_trail_face(d: &mut Draw, card: Card, r: Rect) {
    let w = r.size.width;
    let color = ink(card);
    d.fill(Shape::RoundedRect(r, w * 0.09), FACE);
    d.stroke(Shape::RoundedRect(r, w * 0.09), EDGE, 1.0);
    d.text(
        rank_label(card.rank()),
        Point::new(r.origin.x + w * 0.07, r.origin.y + w * 0.03),
        TextStyle {
            size: w * 0.33,
            color,
            anchor: TextAnchor::LEADING,
            font: chrome::canvas_font(FontWeight::Bold),
        },
    );
    draw_suit(
        d,
        card.suit(),
        Point::new(r.origin.x + w * 0.79, r.origin.y + w * 0.21),
        w * 0.25,
        color,
    );
}

/// A card back in `r`: a blue field, a lattice, and a small sun.
fn draw_back(d: &mut Draw, r: Rect, alpha: f64) {
    let (x, y, w, h) = (r.origin.x, r.origin.y, r.size.width, r.size.height);
    let radius = w * 0.09;
    d.fill(
        Shape::RoundedRect(r, radius),
        LinearGradient::new(
            UnitPoint::TOP,
            UnitPoint::BOTTOM,
            vec![
                (0.0, BACK_TOP.with_alpha(alpha)),
                (1.0, BACK_BOTTOM.with_alpha(alpha)),
            ],
        ),
    );
    d.stroke(Shape::RoundedRect(r, radius), EDGE.with_alpha(alpha), 1.0);
    let inset = w * 0.08;
    let inner = Rect::new(x + inset, y + inset, w - 2.0 * inset, h - 2.0 * inset);
    d.stroke(
        Shape::RoundedRect(inner, radius * 0.6),
        Color::rgba(1.0, 1.0, 1.0, 0.35 * alpha),
        (w * 0.02).max(1.0),
    );
    if w >= 30.0 {
        let q = w * 0.045;
        let step = w * 0.16;
        let mut at = Vec::new();
        let mut py = inner.origin.y + q + step * 0.25;
        let mut row = 0;
        while py < inner.origin.y + inner.size.height - q {
            let mut px = inner.origin.x + q + if row % 2 == 0 { 0.0 } else { step / 2.0 };
            while px < inner.origin.x + inner.size.width - q {
                at.push(Point::new(px, py));
                px += step;
            }
            py += step / 2.0;
            row += 1;
        }
        d.stamp(
            Shape::Polygon(vec![
                Point::new(0.0, -q),
                Point::new(q, 0.0),
                Point::new(0.0, q),
                Point::new(-q, 0.0),
            ]),
            at,
            Color::rgba(1.0, 1.0, 1.0, 0.13 * alpha),
        );
    }
    let c = center(r);
    let s = w * 0.12;
    d.fill(
        Shape::Ellipse(Rect::new(c.x - s * 1.5, c.y - s * 1.5, s * 3.0, s * 3.0)),
        BACK_BOTTOM.with_alpha(alpha),
    );
    d.fill(
        Shape::Ellipse(Rect::new(c.x - s, c.y - s, 2.0 * s, 2.0 * s)),
        chrome::GOLD.with_alpha(0.92 * alpha),
    );
    d.stroke(
        Shape::Ellipse(Rect::new(c.x - s * 1.45, c.y - s * 1.45, s * 2.9, s * 2.9)),
        chrome::GOLD.with_alpha(0.55 * alpha),
        (w * 0.018).max(1.0),
    );
}

/// A card face up or down, squeezed to `sx` of its width about its center (a flip in progress).
fn draw_card(d: &mut Draw, card: Card, r: Rect, up: bool, alpha: f64, sx: f64) {
    if sx >= 0.999 {
        if up {
            draw_face(d, card, r, alpha);
        } else {
            draw_back(d, r, alpha);
        }
        return;
    }
    let c = center(r);
    d.transformed(
        Affine::translate(-c.x, -c.y)
            .then(Affine::scale(sx.max(0.02), 1.0))
            .then(Affine::translate(c.x, c.y)),
        |d| {
            if up {
                draw_face(d, card, r, alpha);
            } else {
                draw_back(d, r, alpha);
            }
        },
    );
}

/// A soft drop shadow under a lifted or moving card.
fn draw_shadow(d: &mut Draw, r: Rect, lift: f64) {
    let w = r.size.width;
    d.fill(
        Shape::RoundedRect(
            Rect::new(
                r.origin.x + w * 0.02 * lift,
                r.origin.y + w * 0.06 * lift,
                r.size.width,
                r.size.height,
            ),
            w * 0.09,
        ),
        Color::rgba(0.0, 0.0, 0.0, 0.18 + 0.10 * lift.min(1.0)),
    );
}

/// What an empty pile shows.
#[derive(Clone, Copy, PartialEq)]
enum Mark {
    None,
    /// A foundation: the ace it waits for.
    Ace,
    /// An empty stock over a waste that can be turned back over.
    Recycle,
    /// An empty stock and waste.
    Spent,
}

fn draw_slot(d: &mut Draw, r: Rect, mark: Mark) {
    let w = r.size.width;
    d.fill(Shape::RoundedRect(r, w * 0.09), SLOT);
    d.stroke(Shape::RoundedRect(r, w * 0.09), SLOT_LINE, 1.5);
    let c = center(r);
    let faint = Color::rgba(1.0, 1.0, 1.0, 0.30);
    match mark {
        Mark::None => {}
        Mark::Ace => d.text(
            "A",
            c,
            TextStyle {
                size: w * 0.42,
                color: faint,
                anchor: TextAnchor::CENTERED,
                font: chrome::canvas_font(FontWeight::Bold),
            },
        ),
        Mark::Recycle => {
            let s = w * 0.26;
            let style = chrome::stroke_style(w * 0.5);
            d.stroke_styled(
                Shape::Arc {
                    rect: Rect::new(c.x - s, c.y - s, 2.0 * s, 2.0 * s),
                    start_deg: -60.0,
                    sweep_deg: 300.0,
                },
                faint.with_alpha(0.55),
                style,
            );
            let tip = Point::new(c.x + s * 0.5, c.y - s * 0.87);
            d.fill(
                Shape::Polygon(vec![
                    Point::new(tip.x + s * 0.40, tip.y - s * 0.10),
                    Point::new(tip.x - s * 0.10, tip.y - s * 0.42),
                    Point::new(tip.x - s * 0.05, tip.y + s * 0.30),
                ]),
                faint.with_alpha(0.55),
            );
        }
        Mark::Spent => d.fill(
            Shape::Ellipse(Rect::new(
                c.x - w * 0.06,
                c.y - w * 0.06,
                w * 0.12,
                w * 0.12,
            )),
            faint,
        ),
    }
}

/// Where everything sits in the canvas: the card size, the columns, the rails or top row, and
/// how far down the columns may reach.
#[derive(Clone, Copy, Default)]
struct Layout {
    cw: f64,
    ch: f64,
    /// Each column's left edge.
    x: [f64; COLS],
    top: f64,
    bottom: f64,
    found: [Point; 4],
    stock: Point,
    /// The waste's top card; the cards under it fan back by `fan` each (draw three).
    waste: Point,
    fan: (f64, f64),
}

impl Layout {
    fn card(&self, at: Point) -> Rect {
        Rect::new(at.x, at.y, self.cw, self.ch)
    }
}

/// Lay the table out for `sz`, choosing whichever arrangement gives the bigger cards: across the
/// top on a phone held upright, rails either side on a landscape phone, a tablet or a desktop.
fn layout(sz: Size) -> Layout {
    let pad = (sz.width.min(sz.height) * 0.025).clamp(6.0, 18.0);
    let (w, h) = (
        (sz.width - 2.0 * pad).max(60.0),
        (sz.height - 2.0 * pad).max(60.0),
    );
    // Upright: the top row, then a column of a full run over six face-down cards.
    let top_cw = (w / (7.0 + 6.0 * GAP)).min(h / (6.0 * ASPECT)).min(MAX_CW);
    // Rails: nine card widths across; four foundations stacked, or that same column, down.
    let side_cw = (w / (9.0 + 8.0 * GAP + 0.6))
        .min(h / (4.72 * ASPECT))
        .min(MAX_CW);
    let side = side_cw > top_cw * 1.04;
    let cw = if side { side_cw } else { top_cw };
    let (ch, g) = (cw * ASPECT, cw * GAP);
    let mut l = Layout {
        cw,
        ch,
        bottom: sz.height - pad,
        ..Layout::default()
    };
    if side {
        let rail = cw * 0.3;
        let width = 9.0 * cw + 8.0 * g + 2.0 * rail;
        let x0 = (sz.width - width) / 2.0;
        let left = x0;
        let first = x0 + cw + g + rail;
        for (c, x) in l.x.iter_mut().enumerate() {
            *x = first + c as f64 * (cw + g);
        }
        let right = l.x[COLS - 1] + cw + g + rail;
        for (i, f) in l.found.iter_mut().enumerate() {
            *f = Point::new(left, pad + i as f64 * (ch + g));
        }
        l.stock = Point::new(right, pad);
        l.fan = (0.0, -ch * 0.22);
        l.waste = Point::new(right, pad + ch + 2.0 * g + 2.0 * ch * 0.22);
        l.top = pad;
    } else {
        let width = 7.0 * cw + 6.0 * g;
        let x0 = (sz.width - width) / 2.0;
        for (c, x) in l.x.iter_mut().enumerate() {
            *x = x0 + c as f64 * (cw + g);
        }
        for (i, f) in l.found.iter_mut().enumerate() {
            *f = Point::new(l.x[i], pad);
        }
        l.stock = Point::new(l.x[6], pad);
        l.waste = Point::new(l.x[5], pad);
        l.fan = (-cw * FAN3, 0.0);
        l.top = pad + ch + ch * 0.22;
    }
    l
}

/// Where a card rests: its rect, whether it lies face up, and its drawing order.
#[derive(Clone, Copy)]
struct Rest {
    rect: Rect,
    up: bool,
    z: u16,
}

impl Default for Rest {
    fn default() -> Self {
        Rest {
            rect: Rect::new(0.0, 0.0, 0.0, 0.0),
            up: false,
            z: 0,
        }
    }
}

/// Where a card is drawn this frame: at rest, in flight, held or shaking.
#[derive(Clone, Copy)]
struct Drawn {
    rect: Rect,
    up: bool,
    /// Horizontal squeeze while it flips (1 when flat).
    sx: f64,
    /// How far it is lifted off the table (0 at rest), for its shadow.
    lift: f64,
    /// Drawn by the moving layer rather than the resting one.
    moving: bool,
}

/// A card travelling from where it was drawn to where it now rests, turning over on the way
/// when its face changes.
struct Flight {
    card: u8,
    from: Rect,
    from_up: bool,
    age: f64,
    delay: f64,
    dur: f64,
    /// How high it arcs.
    arc: f64,
}

/// A run picked up by a finger or pointer.
struct Held {
    from: Pile,
    count: usize,
    cards: Vec<Card>,
    /// From the pointer to the first card's top-left.
    grab: Point,
    at: Point,
    /// How far above the finger it rides.
    lift: f64,
    /// A lean in the direction of travel, eased.
    tilt: f64,
    /// The spacing of the run while carried.
    step: f64,
    /// The legal pile under it.
    target: Option<Pile>,
}

/// A keyboard pick: a pile and how many of its top cards.
#[derive(Clone, Copy, PartialEq, Debug)]
struct Sel {
    pile: Pile,
    count: usize,
}

/// A hint on screen: the move it suggests, if any.
struct HintShow {
    mv: Option<Move>,
    age: f64,
}

struct Particle {
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    life: f64,
    max: f64,
    color: Color,
    size: f64,
    angle: f64,
    spin: f64,
}

struct Popup {
    text: String,
    x: f64,
    y: f64,
    age: f64,
    color: Color,
}

struct Banner {
    text: String,
    sub: Option<String>,
    big: bool,
    age: f64,
}

struct Confetti {
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    angle: f64,
    spin: f64,
    color: Color,
    w: f64,
    h: f64,
    life: f64,
}

/// An expanding ring where a card landed home or a column came clear.
struct Ring {
    at: Point,
    size: f64,
    color: Color,
    age: f64,
}

/// A card bouncing off the table after the win.
struct Bouncer {
    card: Card,
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    stamp: (f64, f64),
}

/// The win: every card leaves the foundations in turn and bounces away, leaving a trail.
struct Cascade {
    order: Vec<Card>,
    launched: usize,
    next: f64,
    bouncers: Vec<Bouncer>,
    trail: Vec<(Card, f64, f64)>,
    /// Cards that have left their foundation.
    gone: u64,
    /// Time since the last card left the screen.
    after: f64,
    last_bump: f64,
    /// The results card has been asked for.
    over: bool,
}

/// The deck being shuffled while a winnable deal is searched for.
struct Shuffle {
    age: f64,
    mode: DrawMode,
    search: Option<DealSearch>,
    found: Option<(Table, bool)>,
}

/// Everything on screen that is not the rules.
struct Fx {
    flights: Vec<Flight>,
    held: Option<Held>,
    shakes: Vec<(u8, f64)>,
    particles: Vec<Particle>,
    popups: Vec<Popup>,
    banner: Option<Banner>,
    confetti: Vec<Confetti>,
    rings: Vec<Ring>,
    /// The movable run under a mouse pointer.
    hover: Option<Sel>,
    sel: Option<Sel>,
    hint: Option<HintShow>,
    shuffle: Option<Shuffle>,
    /// Counting down to the next card home while finishing.
    finish: Option<f64>,
    cascade: Option<Cascade>,
    /// Time since the position ran out of moves.
    stuck: Option<f64>,
    t: f64,
    rng: FxRng,
    shown_score: f64,
}

impl Fx {
    fn new(seed: u64, score: i64) -> Fx {
        Fx {
            flights: Vec::new(),
            held: None,
            shakes: Vec::new(),
            particles: Vec::new(),
            popups: Vec::new(),
            banner: None,
            confetti: Vec::new(),
            rings: Vec::new(),
            hover: None,
            sel: None,
            hint: None,
            shuffle: None,
            finish: None,
            cascade: None,
            stuck: None,
            t: 0.0,
            rng: FxRng(seed | 1),
            shown_score: score as f64,
        }
    }
}

/// The rules plus their presentation, borrowed together by the canvases and their handlers.
struct Play {
    model: Model,
    fx: Fx,
    lay: Layout,
    size: Size,
    /// Bumped on every change to the cards, so the resting layer knows to re-record.
    version: u64,
    /// The version last checked for running out of moves.
    checked: u64,
}

impl Play {
    fn new(model: Model, seed: u64) -> Play {
        let score = model.score;
        Play {
            model,
            fx: Fx::new(seed, score),
            lay: Layout::default(),
            size: Size::new(0.0, 0.0),
            version: 0,
            checked: u64::MAX,
        }
    }

    /// How far apart a column's face-down and face-up cards sit, squeezed to fit its height.
    fn fan(&self, col: usize) -> (f64, f64) {
        let (l, t) = (&self.lay, &self.model.table);
        let hidden = t.hidden[col] as f64;
        let face = t.tableau[col].len().saturating_sub(t.hidden[col]);
        let gaps = face.saturating_sub(1) as f64;
        let avail = (l.bottom - l.top - l.ch).max(0.0);
        let (mut down, mut up) = (DOWN * l.ch, UP * l.ch);
        if hidden * down + gaps * up > avail && gaps > 0.0 {
            up = ((avail - hidden * down) / gaps).clamp(MIN_UP * l.ch, up);
        }
        if hidden * down + gaps * up > avail && hidden > 0.0 {
            down = ((avail - gaps * up) / hidden).clamp(MIN_DOWN * l.ch, down);
        }
        (down, up)
    }

    /// Where every card rests, indexed by card.
    fn rests(&self) -> [Rest; 52] {
        let (l, t) = (&self.lay, &self.model.table);
        let mut out = [Rest::default(); 52];
        let mut z = 0u16;
        let mut put = |card: Card, rect: Rect, up: bool| {
            out[card.0 as usize] = Rest { rect, up, z };
            z += 1;
        };
        for &c in &t.stock {
            put(c, l.card(l.stock), false);
        }
        let n = t.waste.len();
        let shown = if self.model.mode == DrawMode::Three {
            3.min(n)
        } else {
            1
        };
        for (i, &c) in t.waste.iter().enumerate() {
            // The top card sits at the waste's spot; the fanned ones back off from it.
            let back = (n - 1 - i).min(shown.saturating_sub(1)) as f64;
            let at = Point::new(l.waste.x + l.fan.0 * back, l.waste.y + l.fan.1 * back);
            put(c, l.card(at), true);
        }
        for (f, pile) in t.foundations.iter().enumerate() {
            for &c in pile {
                put(c, l.card(l.found[f]), true);
            }
        }
        for (col, cards) in t.tableau.iter().enumerate() {
            let (down, up) = self.fan(col);
            let mut y = l.top;
            for (i, &c) in cards.iter().enumerate() {
                let face = i >= t.hidden[col];
                put(c, l.card(Point::new(l.x[col], y)), face);
                y += if face { up } else { down };
            }
        }
        out
    }

    /// Where every card is drawn this frame.
    fn drawn(&self, rests: &[Rest; 52]) -> [Drawn; 52] {
        let mut out: [Drawn; 52] = std::array::from_fn(|i| Drawn {
            rect: rests[i].rect,
            up: rests[i].up,
            sx: 1.0,
            lift: 0.0,
            moving: false,
        });
        for f in &self.fx.flights {
            let rest = rests[f.card as usize];
            let t = ((f.age - f.delay) / f.dur).clamp(0.0, 1.0);
            let d = &mut out[f.card as usize];
            d.moving = true;
            if f.age < f.delay {
                d.rect = f.from;
                d.up = f.from_up;
                continue;
            }
            let e = ease_in_out(t);
            let mut r = lerp_rect(f.from, rest.rect, e);
            r.origin.y -= f.arc * (PI * t).sin();
            d.rect = r;
            d.lift = (PI * t).sin();
            if f.from_up != rest.up {
                d.up = if t < 0.5 { f.from_up } else { rest.up };
                d.sx = (PI * t).cos().abs();
            }
        }
        for &(c, age) in &self.fx.shakes {
            let d = &mut out[c as usize];
            let k = 1.0 - age / SHAKE_DUR;
            d.rect.origin.x += self.lay.cw * 0.09 * k * (age * 60.0).sin();
            d.moving = true;
        }
        if let Some(h) = &self.fx.held {
            for (i, c) in h.cards.iter().enumerate() {
                let d = &mut out[c.0 as usize];
                d.rect = Rect::new(
                    h.at.x + h.grab.x,
                    h.at.y + h.grab.y - h.lift + i as f64 * h.step,
                    self.lay.cw,
                    self.lay.ch,
                );
                d.up = true;
                d.sx = 1.0;
                d.lift = 1.0;
                d.moving = true;
            }
        }
        if let Some(c) = &self.fx.cascade {
            for (i, d) in out.iter_mut().enumerate() {
                if c.gone & (1 << i) != 0 {
                    d.moving = true;
                }
            }
        }
        out
    }

    fn drawn_now(&self) -> [Drawn; 52] {
        let rests = self.rests();
        self.drawn(&rests)
    }

    /// Fly every card whose resting place or face changed from where `before` drew it.
    fn animate(&mut self, before: &[Drawn; 52], delay_of: &dyn Fn(Card) -> f64) {
        let rests = self.rests();
        for (i, (b, r)) in before.iter().zip(rests.iter()).enumerate() {
            let dx = r.rect.origin.x - b.rect.origin.x;
            let dy = r.rect.origin.y - b.rect.origin.y;
            let dw = (r.rect.size.width - b.rect.size.width).abs();
            if dx.abs() + dy.abs() + dw < 0.5 && b.up == r.up {
                continue;
            }
            self.fx.flights.retain(|f| f.card as usize != i);
            let dist = (dx * dx + dy * dy).sqrt();
            self.fx.flights.push(Flight {
                card: i as u8,
                from: b.rect,
                from_up: b.up,
                age: 0.0,
                delay: delay_of(Card(i as u8)),
                dur: (FLY_MIN + dist / 2600.0).min(FLY_MAX),
                arc: (dist * 0.08).min(self.lay.ch * 0.35),
            });
        }
    }

    /// Make a move with its animation and effects, from where the cards are drawn now or from
    /// `before` (a drop, whose cards are where the finger left them).
    fn perform(&mut self, m: Move, before: Option<[Drawn; 52]>) -> Option<Outcome> {
        let before = before.unwrap_or_else(|| self.drawn_now());
        let out = self.model.apply(m)?;
        self.version += 1;
        self.fx.hint = None;
        self.fx.stuck = None;
        let t = &self.model.table;
        let delay: Box<dyn Fn(Card) -> f64> = if out.recycled {
            // The waste goes back over top card first.
            let stock = t.stock.clone();
            Box::new(move |c| {
                stock
                    .iter()
                    .position(|&s| s == c)
                    .map_or(0.0, |i| i as f64 * 0.012)
            })
        } else if out.drew > 1 {
            let drawn: Vec<Card> = t.waste[t.waste.len() - out.drew..].to_vec();
            Box::new(move |c| {
                drawn
                    .iter()
                    .position(|&s| s == c)
                    .map_or(0.0, |i| i as f64 * 0.07)
            })
        } else {
            Box::new(|_| 0.0)
        };
        self.animate(&before, &*delay);
        self.effects(&out, m);
        Some(out)
    }

    fn undo(&mut self) -> bool {
        let before = self.drawn_now();
        if !self.model.undo() {
            return false;
        }
        self.version += 1;
        self.fx.hint = None;
        self.fx.stuck = None;
        self.fx.finish = None;
        self.animate(&before, &|_| 0.0);
        true
    }

    /// Put a freshly shuffled game on the table and deal it out from the stock, a column at a
    /// time, the way a dealer does.
    fn deal(&mut self, model: Model) {
        let (seed, best) = (self.fx.rng.next(), 0);
        self.model = model;
        self.fx = Fx::new(seed, best);
        self.version += 1;
        let from = self.lay.card(self.lay.stock);
        let t = &self.model.table;
        let order: Vec<Card> = model::deal_order()
            .filter_map(|(col, row)| t.tableau[col].get(row).copied())
            .collect();
        for (k, card) in order.into_iter().enumerate() {
            self.fx.flights.push(Flight {
                card: card.0,
                from,
                from_up: false,
                age: 0.0,
                delay: 0.08 + k as f64 * DEAL_STAGGER,
                dur: 0.30,
                arc: self.lay.ch * 0.25,
            });
        }
    }

    /// Where a pile's top card rests, or the pile's own spot when it is empty.
    fn pile_rect(&self, pile: Pile, rests: &[Rest; 52]) -> Rect {
        let l = &self.lay;
        if let Some(c) = self.model.table.pile(pile).last() {
            return rests[c.0 as usize].rect;
        }
        match pile {
            Pile::Stock => l.card(l.stock),
            Pile::Waste => l.card(l.waste),
            Pile::Foundation(i) => l.card(l.found[i.min(3)]),
            Pile::Tableau(c) => l.card(Point::new(l.x[c.min(COLS - 1)], l.top)),
        }
    }

    /// Everything a move sets off on screen besides the cards flying.
    fn effects(&mut self, out: &Outcome, m: Move) {
        let rests = self.rests();
        let scale = (self.lay.cw / 70.0).clamp(0.7, 1.6);
        if let Some(card) = out.homed {
            let r = rests[card.0 as usize].rect;
            let c = center(r);
            let gold = chrome::GOLD;
            self.fx.rings.push(Ring {
                at: c,
                size: r.size.width,
                color: gold,
                age: 0.0,
            });
            let colors = [gold, ink(card), Color::WHITE];
            for k in 0..14 {
                let a = self.fx.rng.range(0.0, TAU);
                let v = self.fx.rng.range(80.0, 260.0) * scale;
                let life = self.fx.rng.range(0.4, 0.8);
                self.fx.particles.push(Particle {
                    x: c.x,
                    y: c.y,
                    vx: a.cos() * v,
                    vy: a.sin() * v - 120.0 * scale,
                    life,
                    max: life,
                    color: colors[k % 3],
                    size: self.fx.rng.range(3.0, 6.0) * scale,
                    angle: self.fx.rng.range(0.0, TAU),
                    spin: self.fx.rng.range(-10.0, 10.0),
                });
            }
            if out.suit_done {
                self.fx.banner = Some(Banner {
                    text: tr("sol_suit_done").format(),
                    sub: None,
                    big: false,
                    age: 0.0,
                });
                self.burst(c, 70);
            }
        }
        if let Some((_, card)) = out.revealed {
            let c = center(rests[card.0 as usize].rect);
            for _ in 0..8 {
                let a = self.fx.rng.range(0.0, TAU);
                let v = self.fx.rng.range(40.0, 140.0) * scale;
                let life = self.fx.rng.range(0.3, 0.6);
                self.fx.particles.push(Particle {
                    x: c.x,
                    y: c.y,
                    vx: a.cos() * v,
                    vy: a.sin() * v - 60.0 * scale,
                    life,
                    max: life,
                    color: Color::rgba(1.0, 1.0, 1.0, 0.9),
                    size: self.fx.rng.range(2.0, 4.0) * scale,
                    angle: 0.0,
                    spin: 0.0,
                });
            }
        }
        if let Some(col) = out.emptied {
            let r = self.pile_rect(Pile::Tableau(col), &rests);
            self.fx.rings.push(Ring {
                at: center(r),
                size: r.size.width,
                color: Color::rgba(1.0, 1.0, 1.0, 0.8),
                age: 0.0,
            });
        }
        if out.gain != 0 && !out.won {
            let at = match (out.revealed, m) {
                (Some((_, card)), _) => rests[card.0 as usize].rect,
                (None, Move::Shift { to, .. }) => self.pile_rect(to, &rests),
                (None, Move::Draw) => self.pile_rect(Pile::Stock, &rests),
            };
            let c = center(at);
            self.fx.popups.push(Popup {
                text: if out.gain > 0 {
                    format!("+{}", out.gain)
                } else {
                    format!("−{}", -out.gain)
                },
                x: c.x,
                y: c.y,
                age: 0.0,
                color: if out.gain > 0 {
                    chrome::GOLD
                } else {
                    Color::rgb(1.0, 0.55, 0.55)
                },
            });
        }
    }

    /// Confetti thrown up from `at`.
    fn burst(&mut self, at: Point, n: usize) {
        let scale = (self.lay.cw / 70.0).clamp(0.7, 1.6);
        let palette = [
            chrome::GOLD,
            RED_INK,
            Color::WHITE,
            SELECT,
            Color::rgb(0.45, 0.85, 0.45),
        ];
        for _ in 0..n {
            let a = self.fx.rng.range(-PI * 0.9, -PI * 0.1);
            let v = self.fx.rng.range(240.0, 620.0) * scale;
            self.fx.confetti.push(Confetti {
                x: at.x,
                y: at.y,
                vx: a.cos() * v,
                vy: a.sin() * v,
                angle: self.fx.rng.range(0.0, TAU),
                spin: self.fx.rng.range(-8.0, 8.0),
                color: palette[self.fx.rng.below(palette.len())],
                w: self.fx.rng.range(5.0, 9.0) * scale,
                h: self.fx.rng.range(8.0, 13.0) * scale,
                life: CONFETTI_LIFE,
            });
        }
    }
}

/// What a point on the table lands on.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Hit {
    Stock,
    /// A face-up card and the run from it to the top of its pile.
    Run(Sel),
    Nothing,
}

/// The outcome of a tap, a drop or a key, for the haptics.
enum Action {
    Moved(Outcome),
    Drew(Outcome),
    Undone,
    /// Picked up or selected something.
    Picked,
    /// Nothing legal: shaken, or flown back.
    Refused,
    Nothing,
}

impl Play {
    /// Whether the player may touch the cards now.
    fn live(&self) -> bool {
        !self.model.won
            && self.fx.shuffle.is_none()
            && self.fx.finish.is_none()
            && self.fx.cascade.is_none()
    }

    fn hit(&self, p: Point, slop: f64) -> Hit {
        let rests = self.rests();
        let t = &self.model.table;
        if contains(self.lay.card(self.lay.stock), p, slop) {
            return Hit::Stock;
        }
        if let Some(c) = t.waste.last()
            && contains(rests[c.0 as usize].rect, p, slop)
        {
            return Hit::Run(Sel {
                pile: Pile::Waste,
                count: 1,
            });
        }
        for (f, pile) in t.foundations.iter().enumerate() {
            if !pile.is_empty() && contains(self.lay.card(self.lay.found[f]), p, slop) {
                return Hit::Run(Sel {
                    pile: Pile::Foundation(f),
                    count: 1,
                });
            }
        }
        for (col, cards) in t.tableau.iter().enumerate() {
            // The topmost card under the point wins; face-down cards cannot be taken.
            for (i, c) in cards.iter().enumerate().rev() {
                if contains(rests[c.0 as usize].rect, p, slop) {
                    if i < t.hidden[col] {
                        return Hit::Nothing;
                    }
                    return Hit::Run(Sel {
                        pile: Pile::Tableau(col),
                        count: cards.len() - i,
                    });
                }
            }
        }
        Hit::Nothing
    }

    /// Shake the top `count` cards of `pile`.
    fn refuse(&mut self, pile: Pile, count: usize) {
        let cards = self.model.table.pile(pile);
        for c in &cards[cards.len().saturating_sub(count)..] {
            self.fx.shakes.retain(|s| s.0 != c.0);
            self.fx.shakes.push((c.0, 0.0));
        }
    }

    /// A tap: turn the stock, or send the tapped run to its best spot.
    fn tap(&mut self, p: Point) -> Action {
        if !self.live() || self.fx.held.is_some() {
            return Action::Nothing;
        }
        self.fx.sel = None;
        match self.hit(p, self.lay.cw * 0.06) {
            Hit::Stock => self.draw(),
            Hit::Run(sel) => self.send(sel),
            Hit::Nothing => Action::Nothing,
        }
    }

    fn draw(&mut self) -> Action {
        match self.perform(Move::Draw, None) {
            Some(out) => Action::Drew(out),
            None => Action::Nothing,
        }
    }

    /// Send a run where a tap sends it; the whole run first, then its top card alone.
    fn send(&mut self, sel: Sel) -> Action {
        let target = self
            .model
            .best_target(sel.pile, sel.count)
            .map(|to| (sel.count, to))
            .or_else(|| {
                (sel.count > 1)
                    .then(|| self.model.best_target(sel.pile, 1).map(|to| (1, to)))
                    .flatten()
            });
        let Some((count, to)) = target else {
            self.refuse(sel.pile, sel.count);
            return Action::Refused;
        };
        match self.perform(
            Move::Shift {
                from: sel.pile,
                count,
                to,
            },
            None,
        ) {
            Some(out) => Action::Moved(out),
            None => Action::Nothing,
        }
    }

    /// Start dragging the run under `p`; true when something was picked up.
    fn pick(&mut self, p: Point, pointer: bool) -> bool {
        if !self.live() || self.fx.held.is_some() {
            return false;
        }
        let Hit::Run(sel) = self.hit(p, self.lay.cw * 0.04) else {
            return false;
        };
        self.fx.sel = None;
        self.fx.hint = None;
        let drawn = self.drawn_now();
        let cards: Vec<Card> = {
            let pile = self.model.table.pile(sel.pile);
            pile[pile.len() - sel.count..].to_vec()
        };
        let first = drawn[cards[0].0 as usize].rect;
        let step = if cards.len() > 1 {
            drawn[cards[1].0 as usize].rect.origin.y - first.origin.y
        } else {
            UP * self.lay.ch
        };
        // Cards already flying are taken from where they are.
        self.fx
            .flights
            .retain(|f| !cards.iter().any(|c| c.0 == f.card));
        self.fx.held = Some(Held {
            from: sel.pile,
            count: sel.count,
            cards,
            grab: Point::new(first.origin.x - p.x, first.origin.y - p.y),
            at: p,
            lift: if pointer {
                0.0
            } else {
                LIFT_TOUCH * self.lay.ch
            },
            tilt: 0.0,
            step: step.max(MIN_UP * self.lay.ch),
            target: None,
        });
        self.retarget();
        true
    }

    /// Follow the finger; true when the run moved over a new legal pile.
    fn hold_at(&mut self, p: Point) -> bool {
        let Some(h) = self.fx.held.as_mut() else {
            return false;
        };
        let dx = p.x - h.at.x;
        h.tilt = (h.tilt * 0.6 + (dx * 0.012).clamp(-0.20, 0.20) * 0.4).clamp(-0.2, 0.2);
        h.at = p;
        let before = h.target;
        self.retarget();
        let after = self.fx.held.as_ref().and_then(|h| h.target);
        after.is_some() && after != before
    }

    /// The legal pile the held run overlaps most.
    fn retarget(&mut self) {
        let Some(h) = &self.fx.held else {
            return;
        };
        let rests = self.rests();
        let l = &self.lay;
        let first = Rect::new(h.at.x + h.grab.x, h.at.y + h.grab.y - h.lift, l.cw, l.ch);
        let mut best: Option<(f64, Pile)> = None;
        let piles = (0..4)
            .map(Pile::Foundation)
            .chain((0..COLS).map(Pile::Tableau));
        for pile in piles {
            if pile == h.from || !self.model.can_shift(h.from, h.count, pile) {
                continue;
            }
            let mut r = self.pile_rect(pile, &rests);
            if let Pile::Tableau(_) = pile {
                // A column takes a drop anywhere down its length.
                r.size.height += l.ch * 0.6;
            }
            let area = overlap(first, r);
            if area > l.cw * l.ch * 0.08 && best.is_none_or(|(a, _)| area > a) {
                best = Some((area, pile));
            }
        }
        let target = best.map(|(_, p)| p);
        if let Some(h) = self.fx.held.as_mut() {
            h.target = target;
        }
    }

    /// Let go: onto the pile under it, or back where it came from.
    fn release(&mut self) -> Action {
        let before = self.drawn_now();
        let Some(h) = self.fx.held.take() else {
            return Action::Nothing;
        };
        if let Some(to) = h.target
            && let Some(out) = self.perform(
                Move::Shift {
                    from: h.from,
                    count: h.count,
                    to,
                },
                Some(before),
            )
        {
            return Action::Moved(out);
        }
        // Back home from where it was let go.
        let barely_moved = self.hit(h.at, 0.0)
            == Hit::Run(Sel {
                pile: h.from,
                count: h.count,
            });
        self.animate(&before, &|_| 0.0);
        if barely_moved {
            Action::Nothing
        } else {
            Action::Refused
        }
    }

    /// Put a held run back without moving it (a pause, a card over the table).
    fn drop_held(&mut self) {
        if self.fx.held.is_some() {
            let before = self.drawn_now();
            self.fx.held = None;
            self.animate(&before, &|_| 0.0);
        }
    }

    /// The keyboard pick for `pile`: the whole face-up run of a column, else its top card.
    fn select(&mut self, pile: Pile) -> Action {
        let t = &self.model.table;
        let count = match pile {
            Pile::Tableau(c) => t.face_up(c),
            _ => usize::from(!t.pile(pile).is_empty()),
        };
        if count == 0 {
            return Action::Refused;
        }
        self.fx.sel = Some(Sel { pile, count });
        self.fx.hint = None;
        Action::Picked
    }

    /// A pick moved onto `to`: as many of the picked cards as can go.
    fn place(&mut self, sel: Sel, to: Pile) -> Action {
        self.fx.sel = None;
        let count = (1..=sel.count)
            .rev()
            .find(|&n| self.model.can_shift(sel.pile, n, to));
        let Some(count) = count else {
            self.refuse(sel.pile, sel.count);
            return Action::Refused;
        };
        match self.perform(
            Move::Shift {
                from: sel.pile,
                count,
                to,
            },
            None,
        ) {
            Some(out) => Action::Moved(out),
            None => Action::Nothing,
        }
    }

    /// Keys: 1–7 a column, 8 the waste, 9 home, 0 the stock; the same pile twice sends it where
    /// a tap would; the arrows move the pick between piles and change how many cards it takes;
    /// Backspace or Delete drops the pick, or undoes when there is none.
    fn key(&mut self, key: &str) -> Action {
        if !self.live() || self.fx.held.is_some() {
            return Action::Nothing;
        }
        let pile = match key {
            "1" | "2" | "3" | "4" | "5" | "6" | "7" => {
                Some(Pile::Tableau(key.as_bytes()[0] as usize - b'1' as usize))
            }
            "8" => Some(Pile::Waste),
            _ => None,
        };
        if let Some(pile) = pile {
            return match self.fx.sel {
                Some(sel) if sel.pile == pile => {
                    self.fx.sel = None;
                    self.send(sel)
                }
                Some(sel) if matches!(pile, Pile::Tableau(_)) => self.place(sel, pile),
                _ => self.select(pile),
            };
        }
        match key {
            "0" => {
                self.fx.sel = None;
                self.draw()
            }
            "9" => {
                // Home: the pick's top card, else the first card anywhere that can go.
                let from = self.fx.sel.take().map(|s| s.pile).or_else(|| {
                    std::iter::once(Pile::Waste)
                        .chain((0..COLS).map(Pile::Tableau))
                        .find(|&p| {
                            self.model.table.pile(p).last().is_some_and(|&c| {
                                self.model.table.foundation_slot(c).is_some_and(|f| {
                                    self.model.can_shift(p, 1, Pile::Foundation(f))
                                })
                            })
                        })
                });
                let Some(from) = from else {
                    return Action::Refused;
                };
                let slot = self
                    .model
                    .table
                    .pile(from)
                    .last()
                    .and_then(|&c| self.model.table.foundation_slot(c));
                match slot {
                    Some(f) => self.place(
                        Sel {
                            pile: from,
                            count: 1,
                        },
                        Pile::Foundation(f),
                    ),
                    None => {
                        self.refuse(from, 1);
                        Action::Refused
                    }
                }
            }
            "ArrowLeft" | "ArrowRight" => {
                // Walk the pick over the waste and the columns that have cards to take.
                let order: Vec<Pile> = std::iter::once(Pile::Waste)
                    .chain((0..COLS).map(Pile::Tableau))
                    .filter(|&p| match p {
                        Pile::Tableau(c) => self.model.table.face_up(c) > 0,
                        _ => !self.model.table.pile(p).is_empty(),
                    })
                    .collect();
                if order.is_empty() {
                    return Action::Refused;
                }
                let at = self
                    .fx
                    .sel
                    .and_then(|s| order.iter().position(|&p| p == s.pile));
                let next = match (at, key == "ArrowRight") {
                    (None, true) => 0,
                    (None, false) => order.len() - 1,
                    (Some(i), true) => (i + 1) % order.len(),
                    (Some(i), false) => (i + order.len() - 1) % order.len(),
                };
                self.select(order[next])
            }
            "ArrowUp" | "ArrowDown" => {
                let Some(sel) = self.fx.sel else {
                    return Action::Nothing;
                };
                let most = match sel.pile {
                    Pile::Tableau(c) => self.model.table.face_up(c),
                    _ => 1,
                };
                let count = if key == "ArrowUp" {
                    sel.count + 1
                } else {
                    sel.count.saturating_sub(1)
                };
                if count == 0 || count > most {
                    return Action::Refused;
                }
                self.fx.sel = Some(Sel { count, ..sel });
                Action::Picked
            }
            "Backspace" | "Delete" => {
                if self.fx.sel.take().is_some() {
                    Action::Nothing
                } else if self.undo() {
                    Action::Undone
                } else {
                    Action::Refused
                }
            }
            _ => Action::Nothing,
        }
    }
}

/// What a frame did, for the repaint, the HUD, the haptics and the cards.
#[derive(Default)]
struct Tick {
    /// The moving layer needs this frame.
    busy: bool,
    /// The resting layer changed.
    table: bool,
    hud: bool,
    dealt: bool,
    /// A card flew home by itself.
    finished_one: bool,
    won: bool,
    bumped: bool,
    cascade_over: bool,
    stuck: bool,
}

impl Play {
    /// Start shuffling for a new game: searching for a winnable deal, or taking the next one.
    fn shuffle(&mut self, mode: DrawMode, seed: u64, winnable: bool) {
        self.drop_held();
        let (search, found) = if winnable {
            (Some(DealSearch::new(seed, mode)), None)
        } else {
            (None, Some((Table::deal(seed), false)))
        };
        self.fx = Fx::new(seed ^ 0x5011, 0);
        self.fx.shuffle = Some(Shuffle {
            age: 0.0,
            mode,
            search,
            found,
        });
        self.version += 1;
    }

    /// Which cards the moving layer draws, as a mask.
    fn moving_mask(&self) -> u64 {
        let mut m = 0u64;
        for f in &self.fx.flights {
            m |= 1 << f.card;
        }
        for &(c, _) in &self.fx.shakes {
            m |= 1 << c;
        }
        if let Some(h) = &self.fx.held {
            for c in &h.cards {
                m |= 1 << c.0;
            }
        }
        if let Some(c) = &self.fx.cascade {
            m |= c.gone;
        }
        m
    }

    fn table_sig(&self) -> u64 {
        let mut h = self.version.wrapping_mul(0x9E37_79B9_7F4A_7C15);
        h ^= self.moving_mask().rotate_left(7);
        h ^= (self.size.width as u64) << 40 ^ (self.size.height as u64) << 20;
        h ^= u64::from(self.fx.shuffle.is_some()) << 63;
        h
    }

    fn active(&self) -> bool {
        let fx = &self.fx;
        !fx.flights.is_empty()
            || fx.held.is_some()
            || !fx.shakes.is_empty()
            || !fx.particles.is_empty()
            || !fx.popups.is_empty()
            || fx.banner.is_some()
            || !fx.confetti.is_empty()
            || !fx.rings.is_empty()
            || fx.hint.is_some()
            || fx.sel.is_some()
            || fx.shuffle.is_some()
            || fx.finish.is_some()
            || fx.cascade.as_ref().is_some_and(|c| !c.over)
            || fx.shown_score != self.model.score as f64
    }

    /// Advance everything by `dt`.
    fn step(&mut self, dt: f64) -> Tick {
        let mut tick = Tick {
            busy: self.active(),
            ..Tick::default()
        };
        let sig = self.table_sig();
        let secs = self.model.elapsed as u64;
        if self.fx.shuffle.is_none() && self.fx.cascade.is_none() {
            self.model.tick(dt);
        }
        let fx = &mut self.fx;
        fx.t += dt;
        fx.flights.retain_mut(|f| {
            f.age += dt;
            f.age < f.delay + f.dur
        });
        fx.shakes.retain_mut(|s| {
            s.1 += dt;
            s.1 < SHAKE_DUR
        });
        if let Some(h) = fx.held.as_mut() {
            h.tilt *= 1.0 - (8.0 * dt).min(1.0);
        }
        fx.particles.retain_mut(|p| {
            p.vy += 900.0 * dt;
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
            let life = if b.big {
                BANNER_LIFE * 2.2
            } else {
                BANNER_LIFE
            };
            if b.age >= life {
                fx.banner = None;
            }
        }
        let height = self.size.height;
        fx.confetti.retain_mut(|c| {
            c.vy += 380.0 * dt;
            c.vx *= 1.0 - 0.6 * dt;
            c.x += c.vx * dt;
            c.y += c.vy * dt;
            c.angle += c.spin * dt;
            c.life -= dt;
            c.life > 0.0 && c.y < height + 40.0
        });
        fx.rings.retain_mut(|r| {
            r.age += dt;
            r.age < RING_LIFE
        });
        if let Some(h) = fx.hint.as_mut() {
            h.age += dt;
            if h.age >= HINT_LIFE {
                fx.hint = None;
            }
        }
        let before = fx.shown_score.round();
        count_up(&mut fx.shown_score, self.model.score as f64, dt);
        tick.hud = before != fx.shown_score.round() || secs != self.model.elapsed as u64;

        self.step_shuffle(dt, &mut tick);
        self.step_finish(dt, &mut tick);
        self.step_cascade(dt, &mut tick);
        if let Some(t) = self.fx.stuck.as_mut() {
            let was = *t;
            *t += dt;
            tick.stuck = was < STUCK_DELAY && *t >= STUCK_DELAY;
        } else if self.checked != self.version
            && self.live()
            && self.fx.flights.is_empty()
            && self.fx.held.is_none()
        {
            self.checked = self.version;
            if self.model.stuck() {
                self.fx.stuck = Some(0.0);
            }
        }
        tick.table = sig != self.table_sig();
        tick.busy |= self.active();
        tick
    }

    fn step_shuffle(&mut self, dt: f64, tick: &mut Tick) {
        let Some(s) = self.fx.shuffle.as_mut() else {
            return;
        };
        s.age += dt;
        if s.found.is_none()
            && let Some(search) = s.search.as_mut()
        {
            s.found = search.step(SEARCH_BUDGET);
        }
        if s.age >= MIN_SHUFFLE
            && let Some((table, proven)) = s.found.take()
        {
            let mode = s.mode;
            self.fx.shuffle = None;
            self.deal(Model::new(mode, table, proven));
            tick.dealt = true;
        }
    }

    fn step_finish(&mut self, dt: f64, tick: &mut Tick) {
        if self.fx.finish.is_none()
            && self.model.can_finish()
            && self.fx.held.is_none()
            && self.fx.shuffle.is_none()
            && self.fx.flights.is_empty()
        {
            self.fx.finish = Some(FINISH_FIRST);
            self.fx.sel = None;
        }
        let Some(t) = self.fx.finish.as_mut() else {
            return;
        };
        *t -= dt;
        if *t > 0.0 {
            return;
        }
        match self.model.finish_move() {
            Some(m) => {
                self.fx.finish = None;
                self.perform(m, None);
                tick.finished_one = true;
                if !self.model.won {
                    self.fx.finish = Some(FINISH_STEP);
                }
            }
            None => self.fx.finish = None,
        }
    }

    fn step_cascade(&mut self, dt: f64, tick: &mut Tick) {
        if self.model.won && self.fx.cascade.is_none() && self.fx.flights.is_empty() {
            let t = &self.model.table;
            let mut order = Vec::with_capacity(52);
            for depth in (0..13).rev() {
                for pile in &t.foundations {
                    if let Some(&c) = pile.get(depth) {
                        order.push(c);
                    }
                }
            }
            self.fx.cascade = Some(Cascade {
                order,
                launched: 0,
                next: 0.35,
                bouncers: Vec::new(),
                trail: Vec::new(),
                gone: 0,
                after: 0.0,
                last_bump: 0.0,
                over: false,
            });
            self.fx.banner = Some(Banner {
                text: tr("sol_you_win").format(),
                sub: None,
                big: true,
                age: 0.0,
            });
            let top = Point::new(self.size.width / 2.0, self.size.height * 0.35);
            self.burst(top, 110);
            tick.won = true;
        }
        let (l, size) = (self.lay, self.size);
        let scale = (l.cw / 70.0).clamp(0.7, 1.6);
        let t_now = self.fx.t;
        let Some(c) = self.fx.cascade.as_mut() else {
            return;
        };
        if c.over {
            return;
        }
        c.next -= dt;
        while c.next <= 0.0 && c.launched < c.order.len() {
            let card = c.order[c.launched];
            let slot = self
                .model
                .table
                .foundations
                .iter()
                .position(|f| f.contains(&card))
                .unwrap_or(0);
            let at = l.found[slot];
            let dir = if self.fx.rng.below(2) == 0 { -1.0 } else { 1.0 };
            c.bouncers.push(Bouncer {
                card,
                x: at.x,
                y: at.y,
                vx: dir * self.fx.rng.range(150.0, 430.0) * scale,
                vy: -self.fx.rng.range(60.0, 440.0) * scale,
                stamp: (at.x, at.y),
            });
            c.gone |= 1 << card.0;
            c.launched += 1;
            c.next += LAUNCH_EVERY;
        }
        let floor = size.height - l.ch;
        for b in c.bouncers.iter_mut() {
            b.vy += 1800.0 * scale * dt;
            b.x += b.vx * dt;
            b.y += b.vy * dt;
            if b.y > floor {
                b.y = floor;
                b.vy = -b.vy * 0.72;
                if b.vy.abs() > 120.0 && t_now - c.last_bump > 0.09 {
                    c.last_bump = t_now;
                    tick.bumped = true;
                }
            }
            let (sx, sy) = b.stamp;
            if (b.x - sx).hypot(b.y - sy) > l.cw * 0.45 {
                c.trail.push((b.card, b.x, b.y));
                b.stamp = (b.x, b.y);
            }
        }
        c.bouncers
            .retain(|b| b.x > -l.cw * 1.2 && b.x < size.width + l.cw * 0.2);
        if c.trail.len() > TRAIL_MAX {
            let extra = c.trail.len() - TRAIL_MAX;
            c.trail.drain(..extra);
        }
        if c.launched == c.order.len() && c.bouncers.is_empty() {
            c.after += dt;
            if c.after > 0.6 {
                c.over = true;
                tick.cascade_over = true;
            }
        }
    }

    /// Cut the win short (a tap): straight to the results.
    fn skip_cascade(&mut self) -> bool {
        match self.fx.cascade.as_mut() {
            Some(c) if !c.over => {
                c.over = true;
                c.bouncers.clear();
                c.trail.clear();
                c.gone = u64::MAX >> 12;
                true
            }
            _ => false,
        }
    }

    /// The resting layer: the empty spots and every card not on the move.
    fn draw_table(&self, d: &mut Draw) {
        let l = self.lay;
        if l.cw < 8.0 {
            return;
        }
        let t = &self.model.table;
        for f in 0..4 {
            draw_slot(d, l.card(l.found[f]), Mark::Ace);
        }
        let stock_mark = match (t.stock.is_empty(), t.waste.is_empty()) {
            (false, _) => Mark::None,
            (true, false) => Mark::Recycle,
            (true, true) => Mark::Spent,
        };
        draw_slot(d, l.card(l.stock), stock_mark);
        for &x in &l.x {
            draw_slot(d, l.card(Point::new(x, l.top)), Mark::None);
        }
        if self.fx.shuffle.is_some() {
            return;
        }
        let rests = self.rests();
        let moving = self.moving_mask();
        let still = |c: &&Card| moving & (1 << c.0) == 0;
        let draw_top = |d: &mut Draw, cards: &[Card], keep: usize| {
            let still: Vec<&Card> = cards.iter().filter(still).collect();
            for c in &still[still.len().saturating_sub(keep)..] {
                let r = rests[c.0 as usize];
                draw_card(d, **c, r.rect, r.up, 1.0, 1.0);
            }
        };
        draw_top(d, &t.stock, 2);
        draw_top(d, &t.waste, 4);
        for f in &t.foundations {
            draw_top(d, f, 2);
        }
        for col in &t.tableau {
            draw_top(d, col, col.len());
        }
    }

    /// The moving layer: highlights, everything in motion, and the effects.
    fn draw_moving(&self, d: &mut Draw) {
        let l = self.lay;
        if l.cw < 8.0 {
            return;
        }
        let fx = &self.fx;
        let rests = self.rests();
        let drawn = self.drawn(&rests);
        let glow = 0.55 + 0.35 * (fx.t * 6.0).sin();
        let run_rect = |sel: Sel| -> Option<Rect> {
            let cards = self.model.table.pile(sel.pile);
            let run = &cards[cards.len().saturating_sub(sel.count)..];
            let first = drawn[run.first()?.0 as usize].rect;
            let last = drawn[run.last()?.0 as usize].rect;
            Some(Rect::new(
                first.origin.x,
                first.origin.y,
                l.cw,
                last.origin.y + last.size.height - first.origin.y,
            ))
        };
        if fx.held.is_none()
            && let Some(sel) = fx.hover
            && let Some(r) = run_rect(sel)
        {
            outline(d, r, Color::rgba(1.0, 1.0, 1.0, 0.55), 2.0);
        }
        if let Some(sel) = fx.sel
            && let Some(r) = run_rect(sel)
        {
            outline(d, r, SELECT.with_alpha(glow), 3.0);
        }
        if let Some(h) = &fx.hint {
            let fade = (1.0 - (h.age - (HINT_LIFE - 0.4)).max(0.0) / 0.4).clamp(0.0, 1.0);
            let a = glow * fade;
            match h.mv {
                Some(Move::Draw) => outline(d, l.card(l.stock), HINT_GLOW.with_alpha(a), 3.5),
                Some(Move::Shift { from, count, to }) => {
                    if let Some(r) = run_rect(Sel { pile: from, count }) {
                        outline(d, r, HINT_GLOW.with_alpha(a), 3.5);
                    }
                    outline(
                        d,
                        self.pile_rect(to, &rests),
                        HINT_GLOW.with_alpha(a * 0.8),
                        3.0,
                    );
                }
                None => {}
            }
        }
        if let Some(h) = &fx.held
            && let Some(to) = h.target
        {
            let r = self.pile_rect(to, &rests);
            d.fill(
                Shape::RoundedRect(r, l.cw * 0.09),
                chrome::GOLD.with_alpha(0.16),
            );
            outline(d, r, chrome::GOLD.with_alpha(0.9), 3.0);
        }
        if let Some(c) = &fx.cascade {
            for &(card, x, y) in &c.trail {
                draw_trail_face(d, card, Rect::new(x, y, l.cw, l.ch));
            }
        }
        // In flight, lowest destination first so a run lands in order.
        let mut flying: Vec<&Flight> = fx.flights.iter().collect();
        flying.sort_by_key(|f| (f.age >= f.delay, rests[f.card as usize].z));
        for f in flying {
            let dr = drawn[f.card as usize];
            if dr.lift > 0.05 {
                draw_shadow(d, dr.rect, dr.lift);
            }
            draw_card(d, Card(f.card), dr.rect, dr.up, 1.0, dr.sx);
        }
        for &(c, _) in &fx.shakes {
            let dr = drawn[c as usize];
            draw_card(d, Card(c), dr.rect, dr.up, 1.0, 1.0);
        }
        if let Some(h) = &fx.held {
            let pivot = Point::new(h.at.x, h.at.y - h.lift);
            d.transformed(
                Affine::translate(-pivot.x, -pivot.y)
                    .then(Affine::scale(1.05, 1.05))
                    .then(Affine::rotate(h.tilt))
                    .then(Affine::translate(pivot.x, pivot.y)),
                |d| {
                    for c in &h.cards {
                        draw_shadow(d, drawn[c.0 as usize].rect, 1.0);
                    }
                    for c in &h.cards {
                        draw_card(d, *c, drawn[c.0 as usize].rect, true, 1.0, 1.0);
                    }
                },
            );
        }
        if let Some(c) = &fx.cascade {
            for b in &c.bouncers {
                draw_face(d, b.card, Rect::new(b.x, b.y, l.cw, l.ch), 1.0);
            }
        }
        if let Some(s) = &fx.shuffle {
            self.draw_shuffle(d, s);
        }
        self.draw_effects(d);
    }

    /// Two half-decks riffling into one while the search runs.
    fn draw_shuffle(&self, d: &mut Draw, s: &Shuffle) {
        let l = self.lay;
        let c = Point::new(self.size.width / 2.0, self.size.height * 0.42);
        let (w, h) = (l.cw.max(48.0), l.cw.max(48.0) * ASPECT);
        let card_at = |p: Point| Rect::new(p.x - w / 2.0, p.y - h / 2.0, w, h);
        for side in [-1.0, 1.0] {
            let p = Point::new(c.x + side * w * 0.8, c.y);
            draw_shadow(d, card_at(p), 0.6);
            draw_back(d, card_at(p), 1.0);
        }
        draw_back(d, card_at(c), 1.0);
        let mut leaves: Vec<(f64, f64)> = (0..14)
            .map(|k| {
                let phase = (s.age * 2.4 + k as f64 / 14.0).fract();
                let side = if k % 2 == 0 { -1.0 } else { 1.0 };
                (phase, side)
            })
            .collect();
        leaves.sort_by(|a, b| a.0.total_cmp(&b.0));
        for (phase, side) in leaves {
            let e = ease_in_out(phase);
            let p = Point::new(
                lerp(c.x + side * w * 0.8, c.x, e),
                c.y - h * 0.28 * (PI * phase).sin(),
            );
            let r = card_at(p);
            let spin = side * 0.35 * (1.0 - e);
            d.transformed(
                Affine::translate(-p.x, -p.y)
                    .then(Affine::rotate(spin))
                    .then(Affine::translate(p.x, p.y)),
                |d| draw_back(d, r, 1.0),
            );
        }
        let text_y = c.y + h * 0.5 + 26.0;
        outlined_text(
            d,
            &tr("sol_shuffling").format(),
            Point::new(c.x, text_y),
            20.0,
            Color::WHITE,
            1.0,
            None,
        );
        if s.search.is_some() {
            outlined_text(
                d,
                &tr("sol_finding").format(),
                Point::new(c.x, text_y + 24.0),
                14.0,
                Color::rgba(1.0, 1.0, 1.0, 0.8),
                1.0,
                None,
            );
        }
    }

    fn draw_effects(&self, d: &mut Draw) {
        let (l, fx) = (self.lay, &self.fx);
        let scale = (l.cw / 70.0).clamp(0.7, 1.6);
        for r in &fx.rings {
            let t = r.age / RING_LIFE;
            let s = r.size * (1.0 + 0.9 * ease_out(t));
            d.stroke(
                Shape::RoundedRect(
                    Rect::new(r.at.x - s / 2.0, r.at.y - s * 0.7, s, s * 1.4),
                    s * 0.12,
                ),
                r.color.with_alpha(0.85 * (1.0 - t)),
                3.0,
            );
        }
        for p in &fx.particles {
            let a = (p.life / p.max).clamp(0.0, 1.0);
            let s = p.size;
            d.transformed(
                Affine::rotate(p.angle).then(Affine::translate(p.x, p.y)),
                |d| {
                    d.fill(
                        Shape::Polygon(vec![
                            Point::new(0.0, -s),
                            Point::new(s * 0.35, 0.0),
                            Point::new(0.0, s),
                            Point::new(-s * 0.35, 0.0),
                        ]),
                        p.color.with_alpha(a),
                    );
                },
            );
        }
        for p in &fx.popups {
            let t = p.age / POPUP_LIFE;
            let y = p.y - 50.0 * scale * ease_out(t);
            let a = if t < 0.6 { 1.0 } else { 1.0 - (t - 0.6) / 0.4 };
            let size = 18.0 * scale * (0.6 + 0.4 * ease_out_back(p.age / 0.22));
            outlined_text(d, &p.text, Point::new(p.x, y), size, p.color, a, None);
        }
        if let Some(b) = &fx.banner {
            let life = if b.big {
                BANNER_LIFE * 2.2
            } else {
                BANNER_LIFE
            };
            let pop = ease_out_back(b.age / 0.3);
            let fade = ((life - b.age) / 0.4).clamp(0.0, 1.0);
            let size = if b.big { 46.0 } else { 30.0 } * scale.min(1.3);
            let at = Point::new(self.size.width / 2.0, self.size.height * 0.4);
            let wiggle = if b.big { (1.0 - pop) * -0.15 } else { 0.0 };
            d.transformed(
                Affine::scale(0.4 + 0.6 * pop, 0.4 + 0.6 * pop)
                    .then(Affine::rotate(wiggle))
                    .then(Affine::translate(at.x, at.y)),
                |d| {
                    outlined_text(
                        d,
                        &b.text,
                        Point::ZERO,
                        size,
                        chrome::GOLD,
                        fade,
                        Some(chrome::GOLD),
                    );
                    if let Some(sub) = &b.sub {
                        outlined_text(
                            d,
                            sub,
                            Point::new(0.0, size * 0.95),
                            size * 0.5,
                            Color::WHITE,
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
                        c.color.with_alpha(a),
                    );
                },
            );
        }
    }
}

/// A rounded outline just outside `r`.
fn outline(d: &mut Draw, r: Rect, color: Color, width: f64) {
    let o = width / 2.0 + 1.0;
    d.stroke(
        Shape::RoundedRect(
            Rect::new(
                r.origin.x - o,
                r.origin.y - o,
                r.size.width + 2.0 * o,
                r.size.height + 2.0 * o,
            ),
            r.size.width * 0.1 + o,
        ),
        color,
        width,
    );
}

/// Ease the HUD's counted value toward `target`: quick for big jumps, never slower than a point
/// per frame, and straight down for a loss.
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

impl Play {
    /// Put a finished hint search on screen: the first move of a winning line, or, with none
    /// known, the solver's favorite move and, when the solver found the position lost, a word
    /// saying so.
    fn show_hint(&mut self, v: Verdict) {
        let first = |step| self.model.moves_for(step).and_then(|m| m.first().copied());
        let (mv, lost) = match v {
            Verdict::Winnable(path) => (path.first().copied().and_then(first), false),
            Verdict::Unwinnable => (self.model.suggestion().and_then(first), true),
            Verdict::Unknown => (self.model.suggestion().and_then(first), false),
        };
        let mv = mv.or_else(|| self.model.can_draw().then_some(Move::Draw));
        if lost {
            self.fx.banner = Some(Banner {
                text: tr("sol_no_line").format(),
                sub: Some(tr("sol_try_undo").format()),
                big: false,
                age: 0.0,
            });
        }
        self.fx.hint = Some(HintShow { mv, age: 0.0 });
    }

    /// The movable run a pointer hovers, for the highlight.
    fn hover(&mut self, at: Option<Point>) -> bool {
        let next = match at {
            Some(p) if self.live() && self.fx.held.is_none() => match self.hit(p, 0.0) {
                Hit::Run(sel) => Some(sel),
                _ => None,
            },
            _ => None,
        };
        let changed = next != self.fx.hover;
        self.fx.hover = next;
        changed
    }
}

/// This game's settings: gamekit's pair, plus the deal option.
#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
struct Settings {
    #[serde(default = "yes")]
    sounds: bool,
    vibrations: bool,
    instructions_shown: bool,
    #[serde(default = "yes")]
    winnable: bool,
}

fn yes() -> bool {
    true
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            sounds: true,
            vibrations: true,
            instructions_shown: false,
            winnable: true,
        }
    }
}

/// Games, wins and records, per draw mode ([`DrawMode::index`]).
#[derive(Clone, Serialize, Deserialize, Default, Debug, PartialEq)]
struct Stats {
    played: [u32; 2],
    won: [u32; 2],
    best_time: [Option<f64>; 2],
    best_score: [i64; 2],
    streak: u32,
    best_streak: u32,
}

impl Stats {
    /// Count a win; true when it is the fastest yet.
    fn record_win(&mut self, m: &Model) -> bool {
        let i = m.mode.index();
        self.played[i] += 1;
        self.won[i] += 1;
        self.streak += 1;
        self.best_streak = self.best_streak.max(self.streak);
        self.best_score[i] = self.best_score[i].max(m.score);
        let faster = self.best_time[i].is_none_or(|t| m.elapsed < t);
        if faster {
            self.best_time[i] = Some(m.elapsed);
        }
        faster
    }

    fn record_loss(&mut self, mode: DrawMode) {
        self.played[mode.index()] += 1;
        self.streak = 0;
    }
}

fn fmt_time(secs: f64) -> String {
    let s = secs.max(0.0) as u64;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60)
    } else {
        format!("{}:{:02}", s / 60, s % 60)
    }
}

fn draw_label(m: DrawMode) -> day_fluent::LocalizedText {
    match m {
        DrawMode::One => tr("sol_draw_one"),
        DrawMode::Three => tr("sol_draw_three"),
    }
}

fn draw_detail(m: DrawMode) -> day_fluent::LocalizedText {
    match m {
        DrawMode::One => tr("sol_detail_one"),
        DrawMode::Three => tr("sol_detail_three"),
    }
}

fn draw_id(m: DrawMode) -> &'static str {
    match m {
        DrawMode::One => "sol-draw-1",
        DrawMode::Three => "sol-draw-3",
    }
}

fn accent(m: DrawMode) -> Color {
    match m {
        DrawMode::One => Color::rgb(0.35, 0.75, 0.45),
        DrawMode::Three => Color::rgb(0.30, 0.60, 0.95),
    }
}

/// The home-grid tile: a hand of cards fanned over the felt, drawn with the same cards as the
/// game.
pub fn solitaire_preview() -> AnyPiece {
    canvas(|d, sz| {
        if sz.width < 4.0 || sz.height < 4.0 {
            return;
        }
        let full = Rect::new(0.0, 0.0, sz.width, sz.height);
        d.fill(
            Shape::Rect(full),
            RadialGradient::new(UnitPoint::CENTER, 0.75, vec![(0.0, FELT), (1.0, SURFACE)]),
        );
        let w = sz.width.min(sz.height) * 0.36;
        let h = w * ASPECT;
        let pivot = Point::new(sz.width / 2.0, sz.height * 0.98);
        let hand = [
            (Card::new(2, 12), -0.42, true),
            (Card::new(3, 10), -0.14, true),
            (Card::new(1, 13), 0.14, true),
            (Card::new(0, 1), 0.42, true),
        ];
        let base = Rect::new(pivot.x - w / 2.0, pivot.y - h * 1.55, w, h);
        d.transformed(
            Affine::translate(-pivot.x, -pivot.y)
                .then(Affine::rotate(-0.70))
                .then(Affine::translate(pivot.x, pivot.y)),
            |d| draw_back(d, base, 1.0),
        );
        for (card, angle, up) in hand {
            d.transformed(
                Affine::translate(-pivot.x, -pivot.y)
                    .then(Affine::rotate(angle))
                    .then(Affine::translate(pivot.x, pivot.y)),
                |d| {
                    draw_shadow(d, base, 0.5);
                    draw_card(d, card, base, up, 1.0, 1.0);
                },
            );
        }
    })
    .any()
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Overlay {
    None,
    Pause,
    Win,
    Stuck,
    Draw,
    Settings,
    Instructions,
}

struct Ui {
    play: Rc<RefCell<Play>>,
    /// The resting layer: re-recorded when a card comes to rest or leaves it.
    table: Trigger,
    /// The moving layer: every animated frame.
    moving: Trigger,
    /// The HUD's labels and buttons.
    hud: Trigger,
    overlay: Signal<Overlay>,
    /// Where the draw picker's Cancel returns to.
    return_to: Cell<Overlay>,
    sounds: Signal<bool>,
    vibrations: Signal<bool>,
    winnable: Signal<bool>,
    stats: RefCell<Stats>,
    /// A mouse or trackpad is in use: carry cards as grabbed, and highlight under the pointer.
    pointer_seen: Cell<bool>,
    /// A hint search in progress, spread over frames like the deal search.
    hint: RefCell<Option<Solver>>,
    /// The game in hand has already been counted in the statistics.
    counted: Cell<bool>,
    /// The win just recorded was the fastest yet.
    new_best: Cell<bool>,
    /// Cards the finishing run has sent home, so each takes the next chip.
    finishes: Cell<usize>,
}

impl Ui {
    fn haptic(&self, h: Haptic) {
        chrome::haptic(self.vibrations.get_untracked(), h);
    }
    fn feedback(&self) -> Feedback {
        Feedback {
            sounds: self.sounds.get_untracked(),
            vibrations: self.vibrations.get_untracked(),
        }
    }
    fn cue(&self, c: &Cue) {
        chrome::cue(self.feedback(), c);
    }
    /// The deal: its phrase, and a card slide every other beat of it.
    fn dealt(&self) {
        chrome::haptic_pattern(self.vibrations.get_untracked(), DEAL);
        let end = DEAL.last().map_or(0, |beat| beat.0);
        for (i, at) in (0..=end).step_by(DEAL_SLIDE_EVERY as usize).enumerate() {
            chrome::sound_after(
                self.sounds.get_untracked(),
                &DEALS[i % DEALS.len()],
                0.9,
                at,
            );
        }
    }
    /// A card of the finishing run landing home.
    fn finished_one(&self) {
        let n = self.finishes.replace(self.finishes.get() + 1);
        self.haptic(Haptic::Light);
        chrome::sound(
            self.sounds.get_untracked(),
            &FINISHES[n % FINISHES.len()],
            1.0,
        );
    }
    fn refresh(&self) {
        self.table.notify();
        self.moving.notify();
        self.hud.notify();
    }
    fn show(&self, kind: Overlay) {
        self.overlay.set(kind);
        self.refresh();
    }
    fn pause(&self) {
        if self.overlay.get_untracked() == Overlay::None {
            self.play.borrow_mut().drop_held();
            self.show(Overlay::Pause);
        }
    }
    /// New Game asks which game first; the picker deals it.
    fn pick_draw(&self) {
        self.return_to.set(self.overlay.get_untracked());
        self.show(Overlay::Draw);
    }
    fn save_stats(&self) {
        gamekit::save(STATS_KEY, &*self.stats.borrow());
    }
    fn new_game(&self, mode: DrawMode) {
        {
            let p = self.play.borrow();
            if p.model.started() && !p.model.won && !self.counted.get() {
                self.stats.borrow_mut().record_loss(p.model.mode);
            }
        }
        self.save_stats();
        self.counted.set(false);
        self.new_best.set(false);
        *self.hint.borrow_mut() = None;
        self.play
            .borrow_mut()
            .shuffle(mode, gamekit::seed(), self.winnable.get_untracked());
        gamekit::clear(SAVE_KEY);
        self.return_to.set(Overlay::None);
        self.show(Overlay::None);
        self.cue(&SHUFFLE_CUE);
    }
    fn undo(&self) {
        *self.hint.borrow_mut() = None;
        let undone = self.play.borrow_mut().undo();
        self.cue(if undone { &UNDO } else { &cues::WARNING });
        self.refresh();
    }
    fn hint(&self) {
        let solver = {
            let p = self.play.borrow();
            if !p.live() {
                return;
            }
            Solver::new(&p.model.table, p.model.mode, HINT_LIMITS)
        };
        *self.hint.borrow_mut() = Some(solver);
        self.cue(&cues::HINT);
    }
    /// The sounds and haptics for what a move did: the strongest moment leads, a card turning
    /// over and a column coming clear follow it.
    fn feel(&self, out: &Outcome) {
        self.cue(if out.suit_done {
            &SUIT
        } else if out.homed.is_some() {
            &HOME_CUE
        } else if out.recycled {
            &RECYCLE_CUE
        } else if out.drew > 0 {
            &DRAW
        } else {
            &DROP
        });
        if out.revealed.is_some() {
            self.cue(&FLIP);
        }
        if out.emptied.is_some() {
            self.cue(&EMPTIED_CUE);
        }
    }
    fn acted(&self, a: Action) {
        match a {
            Action::Moved(out) | Action::Drew(out) => {
                *self.hint.borrow_mut() = None;
                self.feel(&out);
            }
            Action::Undone => self.cue(&UNDO),
            Action::Picked => self.cue(&PICK),
            Action::Refused => self.cue(&cues::WARNING),
            Action::Nothing => {}
        }
        self.refresh();
    }
    /// The last card went home: count it, and the fanfare as the cards start to bounce.
    fn won(&self) {
        let faster = {
            let p = self.play.borrow();
            self.stats.borrow_mut().record_win(&p.model)
        };
        self.new_best.set(faster);
        self.counted.set(true);
        self.save_stats();
        self.cue(&WIN);
    }
}

/// The Solitaire screen.
pub fn solitaire_page() -> AnyPiece {
    let settings = gamekit::restore::<Settings>(SETTINGS_KEY).unwrap_or_default();
    let stats = gamekit::restore::<Stats>(STATS_KEY).unwrap_or_default();
    let seed = gamekit::seed();
    let restored = gamekit::restore::<Option<model::SaveState>>(SAVE_KEY)
        .flatten()
        .and_then(Model::from_save);
    let fresh = restored.is_none();
    let model = restored.unwrap_or_else(|| Model::new(DrawMode::One, Table::deal(seed), false));
    let won = model.won;
    let mut play = Play::new(model, seed ^ 0x50_11);
    if fresh {
        play.shuffle(DrawMode::One, seed, settings.winnable);
    }
    let ui = Rc::new(Ui {
        play: Rc::new(RefCell::new(play)),
        table: Trigger::new(),
        moving: Trigger::new(),
        hud: Trigger::new(),
        overlay: Signal::new(Overlay::None),
        return_to: Cell::new(Overlay::None),
        sounds: Signal::new(settings.sounds),
        vibrations: Signal::new(settings.vibrations),
        winnable: Signal::new(settings.winnable),
        stats: RefCell::new(stats),
        pointer_seen: Cell::new(false),
        hint: RefCell::new(None),
        counted: Cell::new(won),
        new_best: Cell::new(false),
        finishes: Cell::new(0),
    });
    gamekit::autosave(SAVE_KEY, {
        let play = ui.play.clone();
        move || {
            let p = play.borrow();
            // Mid-shuffle there is no game yet; the one before it was already cleared.
            p.fx.shuffle.is_none().then(|| p.model.save_state())
        }
    });
    gamekit::sounds(SOUNDS);
    Effect::new({
        let ui = ui.clone();
        move || {
            gamekit::save(
                SETTINGS_KEY,
                &Settings {
                    sounds: ui.sounds.get(),
                    vibrations: ui.vibrations.get(),
                    instructions_shown: true,
                    winnable: ui.winnable.get(),
                },
            );
        }
    });
    if !settings.instructions_shown {
        ui.show(Overlay::Instructions);
    } else if won {
        ui.show(Overlay::Win);
    }
    gamekit::on_background(SAVE_KEY, {
        let ui = ui.clone();
        move || ui.pause()
    });

    let felt = canvas(|d, sz| {
        d.fill(
            Shape::Rect(Rect::new(0.0, 0.0, sz.width, sz.height)),
            RadialGradient::new(UnitPoint::CENTER, 0.8, vec![(0.0, FELT), (1.0, SURFACE)]),
        );
    })
    .grow();

    let resting = {
        let u = ui.clone();
        canvas(move |d, sz| {
            u.table.track();
            let mut p = u.play.borrow_mut();
            if p.size != sz {
                p.lay = layout(sz);
                p.size = sz;
            }
            p.draw_table(d);
        })
        .grow()
    };

    let moving = {
        let (du, tu, gu, hu, ku) = (ui.clone(), ui.clone(), ui.clone(), ui.clone(), ui.clone());
        canvas(move |d, sz| {
            du.moving.track();
            let mut p = du.play.borrow_mut();
            if p.size != sz {
                p.lay = layout(sz);
                p.size = sz;
            }
            p.draw_moving(d);
        })
        .on_tap_at(move |at| {
            if tu.overlay.get_untracked() != Overlay::None {
                return;
            }
            let skipped = tu.play.borrow_mut().skip_cascade();
            if skipped {
                tu.show(Overlay::Win);
                return;
            }
            let a = tu.play.borrow_mut().tap(at);
            tu.acted(a);
        })
        .on_drag(move |dg| {
            if gu.overlay.get_untracked() != Overlay::None {
                return;
            }
            let pointer = gu.pointer_seen.get();
            match dg.phase {
                DragPhase::Began => {
                    let start = Point::new(
                        dg.location.x - dg.translation.x,
                        dg.location.y - dg.translation.y,
                    );
                    let picked = {
                        let mut p = gu.play.borrow_mut();
                        let picked = p.pick(start, pointer);
                        if picked {
                            p.hold_at(dg.location);
                        }
                        picked
                    };
                    if picked {
                        gu.cue(&PICKUP);
                    }
                }
                DragPhase::Ended => {
                    let a = gu.play.borrow_mut().release();
                    gu.acted(a);
                }
                _ => {
                    let over = gu.play.borrow_mut().hold_at(dg.location);
                    if over {
                        gu.cue(&cues::TICK);
                    }
                }
            }
            gu.refresh();
        })
        .on_hover(move |at| {
            hu.pointer_seen.set(true);
            if hu.play.borrow_mut().hover(at) {
                hu.moving.notify();
            }
        })
        .on_key(move |k| {
            if ku.overlay.get_untracked() != Overlay::None {
                return;
            }
            let a = ku.play.borrow_mut().key(&k.key);
            ku.acted(a);
        })
        .a11y(|a| a.label(tr("sol_table_a11y").format()))
        .id("sol-canvas")
        .grow()
    };

    // Mounted only while the game is live, so the display link goes idle behind a card.
    let clock = {
        let (cu, bu) = (ui.clone(), ui.clone());
        when(
            move || cu.overlay.get() == Overlay::None,
            move || solitaire_clock(bu.clone()),
        )
    };

    let pu = ui.clone();
    let header = chrome::game_header(tr("nav_solitaire"), "sol-pause", move || {
        pu.pause();
        pu.cue(&cues::SELECT);
    });
    let table = zstack((resting, moving)).grow().any();
    zstack((
        felt,
        chrome::game_frame(
            header,
            Some(info_bar(ui.clone())),
            table,
            Some(tools(ui.clone())),
        ),
        overlays(ui),
        clock,
    ))
    .any()
}

/// The undo arrow, centered at `c` in a `size`-point square.
fn draw_undo_glyph(d: &mut Draw, c: Point, size: f64, color: Color) {
    let s = size / 2.0;
    let p = |x: f64, y: f64| Point::new(c.x + x * s, c.y + y * s);
    let style = chrome::stroke_style(size);
    d.stroke_styled(
        PathBuilder::new()
            .move_to(p(0.55, 0.65))
            .cubic_to(p(0.85, -0.05), p(0.30, -0.60), p(-0.50, -0.20))
            .build(),
        color,
        style.clone(),
    );
    d.stroke_styled(
        PathBuilder::new()
            .move_to(p(-0.18, -0.58))
            .line_to(p(-0.55, -0.20))
            .line_to(p(-0.12, 0.08))
            .build(),
        color,
        style,
    );
}

/// A light bulb, centered at `c` in a `size`-point square.
fn draw_hint_glyph(d: &mut Draw, c: Point, size: f64, color: Color) {
    let s = size / 2.0;
    let p = |x: f64, y: f64| Point::new(c.x + x * s, c.y + y * s);
    let style = chrome::stroke_style(size);
    d.stroke_styled(
        PathBuilder::new().circle(p(0.0, -0.22), 0.48 * s).build(),
        color,
        style.clone(),
    );
    for (a, b) in [
        (p(-0.20, 0.24), p(-0.20, 0.50)),
        (p(0.20, 0.24), p(0.20, 0.50)),
        (p(-0.24, 0.52), p(0.24, 0.52)),
        (p(-0.14, 0.74), p(0.14, 0.74)),
    ] {
        d.stroke_styled(Shape::Line(a, b), color, style.clone());
    }
}

/// A 44-point glyph button for the HUD, dimmed while `enabled` says no.
fn tool_button(
    ui: Rc<Ui>,
    glyph: fn(&mut Draw, Point, f64, Color),
    a11y: day_fluent::LocalizedText,
    id: &'static str,
    enabled: fn(&Ui) -> bool,
    action: fn(&Ui),
) -> AnyPiece {
    let (du, au) = (ui.clone(), ui);
    canvas(move |d, sz| {
        du.hud.track();
        let on = enabled(&du);
        glyph(
            d,
            Point::new(sz.width / 2.0, sz.height / 2.0),
            24.0,
            Color::rgba(1.0, 1.0, 1.0, if on { 0.8 } else { 0.3 }),
        );
    })
    .on_tap(move || {
        if au.overlay.get_untracked() == Overlay::None && enabled(&au) {
            action(&au);
        }
    })
    .a11y(move |a| a.label(a11y.format()).role(Role::Button))
    .id(id)
    .frame(44.0, 44.0)
    .any()
}

/// Score, time and moves, then hint, undo and pause; the leading gutter clears the cover's close
/// button.
/// The readouts under the header: score, clock, moves.
fn info_bar(ui: Rc<Ui>) -> AnyPiece {
    let stat = |caption: day_fluent::LocalizedText,
                value: Box<dyn Fn() -> String>,
                id: &'static str,
                width: f64| {
        chrome::info_stat(caption, value, Color::WHITE, id)
            .min_width(width)
            .any()
    };
    let (su, tu, mu) = (ui.clone(), ui.clone(), ui.clone());
    let score = stat(
        tr("gk_score"),
        Box::new(move || {
            su.hud.track();
            (su.play.borrow().fx.shown_score.round() as i64).to_string()
        }),
        "sol-score",
        58.0,
    );
    let time = stat(
        tr("sol_time"),
        Box::new(move || {
            tu.hud.track();
            fmt_time(tu.play.borrow().model.elapsed)
        }),
        "sol-time",
        50.0,
    );
    let moves = stat(
        tr("sol_moves"),
        Box::new(move || {
            mu.hud.track();
            mu.play.borrow().model.moves.to_string()
        }),
        "sol-moves",
        40.0,
    );
    chrome::info_row(vec![score, time, moves])
}

/// Under the table: the two tools a game reaches for, a hint and an undo.
fn tools(ui: Rc<Ui>) -> AnyPiece {
    let hint = tool_button(
        ui.clone(),
        draw_hint_glyph,
        tr("sol_hint"),
        "sol-hint",
        |u| u.play.borrow().live(),
        |u| u.hint(),
    );
    let undo = tool_button(
        ui.clone(),
        draw_undo_glyph,
        tr("sol_undo"),
        "sol-undo",
        |u| {
            let p = u.play.borrow();
            p.live() && p.model.can_undo()
        },
        |u| u.undo(),
    );
    row((hint, undo))
        .spacing(12.0)
        .align(VAlign::Center)
        .padding(8.0)
        .any()
}

/// The frame consumer: the deal and hint searches, every tween and effect, the HUD, and the
/// cards that come up when the game ends.
fn solitaire_clock(ui: Rc<Ui>) -> impl Piece {
    frame_clock(move |dt| {
        let dt = dt.as_secs_f64().min(0.05);
        let verdict = ui
            .hint
            .borrow_mut()
            .as_mut()
            .and_then(|s| s.run(SEARCH_BUDGET).cloned());
        if let Some(v) = verdict {
            *ui.hint.borrow_mut() = None;
            ui.play.borrow_mut().show_hint(v);
        }
        let tick = ui.play.borrow_mut().step(dt);
        if tick.dealt {
            ui.dealt();
            ui.hud.notify();
        }
        if tick.finished_one {
            ui.finished_one();
        }
        if tick.won {
            ui.won();
        }
        if tick.bumped {
            ui.haptic(Haptic::Light);
            chrome::sound(ui.sounds.get_untracked(), &BOUNCE, BOUNCE_VOLUME);
        }
        if tick.hud {
            ui.hud.notify();
        }
        if tick.table {
            ui.table.notify();
        }
        if tick.busy {
            ui.moving.notify();
        }
        if tick.cascade_over {
            ui.show(Overlay::Win);
        } else if tick.stuck {
            ui.cue(&cues::LETDOWN);
            ui.show(Overlay::Stuck);
        }
    })
}

fn overlays(ui: Rc<Ui>) -> impl Piece {
    let scrim = {
        let u = ui.clone();
        when(move || u.overlay.get() != Overlay::None, chrome::scrim)
    };
    let (p, w, s, d, g, i) = (
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
        card(Overlay::Win, Rc::new(move || win_card(w.clone()))),
        card(Overlay::Stuck, Rc::new(move || stuck_card(s.clone()))),
        card(Overlay::Draw, Rc::new(move || draw_picker(d.clone()))),
        card(Overlay::Settings, Rc::new(move || settings_card(g.clone()))),
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
            chrome::menu_button(tr("gk_resume"), chrome::GREEN, "sol-resume", move || {
                u1.show(Overlay::None)
            }),
            chrome::menu_button(tr("gk_new_game"), chrome::BLUE, "sol-new-game", move || {
                u2.pick_draw()
            }),
            chrome::menu_button(
                tr("gk_settings"),
                chrome::SLATE,
                "sol-settings",
                move || u3.show(Overlay::Settings),
            ),
            chrome::menu_button(
                tr("gk_instructions"),
                chrome::INDIGO,
                "sol-instructions",
                move || u4.show(Overlay::Instructions),
            ),
            chrome::menu_button(tr("gk_quit"), chrome::RED, "sol-quit", || {
                nav_back();
            }),
        ))
        .spacing(14.0)
        .align(HAlign::Center),
    )
    .id("sol-pause-menu")
    .any()
}

fn win_card(ui: Rc<Ui>) -> AnyPiece {
    let (elapsed, moves, score, mode) = {
        let p = ui.play.borrow();
        (p.model.elapsed, p.model.moves, p.model.score, p.model.mode)
    };
    let stats = ui.stats.borrow().clone();
    let i = mode.index();
    let best = stats.best_time[i].unwrap_or(elapsed);
    let faster = ui.new_best.get();
    let record = when(
        move || faster,
        || {
            label(tr("sol_new_best_time"))
                .font(Font::Title3)
                .bold()
                .color(chrome::GOLD)
        },
    );
    let u = ui;
    chrome::card(
        column((
            chrome::card_title(tr("sol_you_win"), chrome::GOLD),
            row((
                chrome::stat(
                    tr("sol_time"),
                    fmt_time(elapsed),
                    Font::Title2,
                    Color::WHITE,
                    "sol-final-time",
                ),
                chrome::stat(
                    tr("sol_moves"),
                    moves.to_string(),
                    Font::Title2,
                    Color::WHITE,
                    "sol-final-moves",
                ),
                chrome::stat(
                    tr("gk_score"),
                    score.to_string(),
                    Font::Title2,
                    chrome::GOLD,
                    "sol-final-score",
                ),
            ))
            .spacing(24.0),
            record,
            chrome::stat(
                tr("sol_best_time"),
                fmt_time(best),
                Font::Title3,
                Color::WHITE,
                "sol-best-time",
            ),
            label(
                tr("sol_record")
                    .arg("won", stats.won[i] as f64)
                    .arg("played", stats.played[i] as f64)
                    .arg("streak", stats.streak as f64),
            )
            .font(Font::Subheadline)
            .color(chrome::TEXT_DIM)
            .id("sol-record"),
            label(draw_label(mode))
                .font(Font::Subheadline)
                .bold()
                .color(accent(mode)),
            chrome::menu_button(
                tr("gk_play_again"),
                chrome::BLUE,
                "sol-play-again",
                move || u.pick_draw(),
            ),
            chrome::menu_button(tr("gk_quit"), chrome::RED, "sol-quit", || {
                nav_back();
            }),
        ))
        .spacing(14.0)
        .align(HAlign::Center),
    )
    .id("sol-win-card")
    .any()
}

fn stuck_card(ui: Rc<Ui>) -> AnyPiece {
    let (u1, u2) = (ui.clone(), ui);
    chrome::card(
        column((
            chrome::card_title(tr("sol_stuck_title"), Color::WHITE),
            label(tr("sol_stuck_message"))
                .color(chrome::TEXT_DIM)
                .align(TextAlign::Center),
            chrome::menu_button(tr("sol_undo"), chrome::GREEN, "sol-stuck-undo", move || {
                u1.show(Overlay::None);
                u1.undo();
            }),
            chrome::menu_button(
                tr("gk_new_game"),
                chrome::BLUE,
                "sol-stuck-new",
                move || u2.pick_draw(),
            ),
            chrome::menu_button(tr("gk_quit"), chrome::RED, "sol-quit", || {
                nav_back();
            }),
        ))
        .spacing(14.0)
        .align(HAlign::Center),
    )
    .id("sol-stuck-card")
    .any()
}

fn draw_picker(ui: Rc<Ui>) -> AnyPiece {
    let current = ui.play.borrow().model.mode;
    let mut cards = Vec::new();
    for m in DRAW_MODES {
        let u = ui.clone();
        let tint = accent(m);
        let check = when(
            move || m == current,
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
                    label(draw_label(m))
                        .font(Font::Title3)
                        .bold()
                        .color(Color::WHITE),
                    label(draw_detail(m))
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
            .on_tap(move || u.new_game(m))
            .a11y(move |a| a.label(draw_label(m).format()).role(Role::Button))
            .id(draw_id(m))
            .width(300.0)
            .any(),
        );
    }
    let u = ui;
    chrome::card(
        column((
            label(tr("sol_choose"))
                .font(Font::Title2)
                .bold()
                .color(Color::WHITE),
            column(PieceVec(cards)).spacing(12.0),
            button(tr("gk_cancel"))
                .action(move || {
                    let back = u.return_to.replace(Overlay::None);
                    u.show(back);
                })
                .id("sol-cancel"),
        ))
        .spacing(16.0)
        .align(HAlign::Center),
    )
    .id("sol-draw-picker")
    .any()
}

fn settings_card(ui: Rc<Ui>) -> AnyPiece {
    let stats = ui.stats.borrow().clone();
    let line = |m: DrawMode| {
        let i = m.index();
        let key = match m {
            DrawMode::One => "sol_stats_one",
            DrawMode::Three => "sol_stats_three",
        };
        let best = stats.best_time[i]
            .map(fmt_time)
            .unwrap_or_else(|| "—".into());
        row((
            label(
                tr(key)
                    .arg("won", stats.won[i] as f64)
                    .arg("played", stats.played[i] as f64),
            )
            .color(chrome::TEXT)
            .grow_w(),
            label(best).tabular().color(chrome::TEXT_DIM),
        ))
        .width(300.0)
        .any()
    };
    let reset = {
        let u = ui.clone();
        button(tr("sol_reset_stats"))
            .tint(chrome::RED)
            .action(move || {
                let u = u.clone();
                day_core::task(async move {
                    let sure = Alert::new(tr("sol_reset_stats_title"))
                        .message(tr("sol_reset_stats_message"))
                        .destructive(tr("gk_reset_confirm"), true)
                        .cancel(tr("gk_cancel"))
                        .present()
                        .await;
                    if sure == Some(true) {
                        *u.stats.borrow_mut() = Stats::default();
                        u.save_stats();
                        u.show(Overlay::Settings);
                    }
                });
            })
            .id("sol-reset-stats")
    };
    let done = ui.clone();
    chrome::card(
        column((
            label(tr("gk_settings"))
                .font(Font::Title2)
                .bold()
                .color(Color::WHITE),
            chrome::section_heading(tr("nav_solitaire")),
            chrome::setting_row(tr("gk_sounds"), toggle(ui.sounds).id("sol-sounds").any()),
            chrome::setting_row(
                tr("gk_vibrations"),
                toggle(ui.vibrations).id("sol-vibrations").any(),
            ),
            chrome::setting_row(
                tr("sol_winnable"),
                toggle(ui.winnable).id("sol-winnable").any(),
            ),
            label(tr("sol_winnable_detail"))
                .font(Font::Caption)
                .color(chrome::TEXT_DIM)
                .width(300.0),
            chrome::section_heading(tr("sol_statistics")),
            line(DrawMode::One),
            line(DrawMode::Three),
            reset,
            button(tr("gk_done"))
                .prominent()
                .action(move || done.show(Overlay::Pause))
                .id("sol-done"),
        ))
        .spacing(12.0)
        .align(HAlign::Center),
    )
    .id("sol-settings-card")
    .any()
}

fn instructions_card(ui: Rc<Ui>) -> AnyPiece {
    let live = {
        let p = ui.play.borrow();
        p.model.started() && !p.model.won
    };
    chrome::instructions_card(
        tr("nav_solitaire"),
        vec![
            Help::Para(tr("sol_help_intro")),
            Help::Heading(tr("sol_help_play")),
            Help::Para(tr("sol_help_play_1")),
            Help::Para(tr("sol_help_play_2")),
            Help::Para(tr("sol_help_play_3")),
            Help::Para(tr("sol_help_play_4")),
            Help::Heading(tr("sol_help_score")),
            Help::Para(tr("sol_help_score_1")),
            Help::Para(tr("sol_help_score_2")),
            Help::Heading(tr("sol_help_winnable")),
            Help::Para(tr("sol_help_winnable_1")),
            Help::Heading(tr("sol_help_keys")),
            Help::Para(tr("sol_help_keys_1")),
        ],
        "sol-help-done",
        move || ui.show(if live { Overlay::Pause } else { Overlay::None }),
    )
    .id("sol-instructions-card")
    .any()
}

#[cfg(test)]
mod tests {
    use super::*;
    use model::DEAL_LIMITS;

    const SIZE: Size = Size::new(400.0, 760.0);

    fn play_with(table: Table, mode: DrawMode) -> Play {
        let mut p = Play::new(Model::new(mode, table, false), 7);
        p.lay = layout(SIZE);
        p.size = SIZE;
        p
    }

    fn settle(p: &mut Play) {
        for _ in 0..900 {
            p.step(1.0 / 60.0);
        }
        assert!(p.fx.flights.is_empty() && p.fx.shakes.is_empty());
    }

    fn deal_with(pred: impl Fn(&Table) -> bool) -> Table {
        (1..2000)
            .map(Table::deal)
            .find(|t| pred(t))
            .expect("some deal has it")
    }

    fn middle(p: &Play, card: Card) -> Point {
        center(p.rests()[card.0 as usize].rect)
    }

    fn top(t: &Table, col: usize) -> Card {
        *t.tableau[col].last().unwrap()
    }

    #[test]
    fn a_tap_sends_an_ace_home_and_it_flies_there() {
        let t = deal_with(|t| (0..COLS).any(|c| top(t, c).rank() == 1));
        let col = (0..COLS).find(|&c| top(&t, c).rank() == 1).unwrap();
        let ace = top(&t, col);
        let mut p = play_with(t, DrawMode::One);
        let at = middle(&p, ace);
        let Action::Moved(out) = p.tap(at) else {
            panic!("the ace moves");
        };
        assert_eq!(out.homed, Some(ace));
        assert!(
            p.fx.flights.iter().any(|f| f.card == ace.0),
            "it flies home"
        );
        settle(&mut p);
        assert!(p.model.table.foundations.iter().any(|f| f == &vec![ace]));
    }

    #[test]
    fn a_drag_onto_a_legal_column_moves_the_card() {
        let pair = |t: &Table| {
            (0..COLS).find_map(|a| {
                (0..COLS)
                    .find(|&b| b != a && top(t, a).stacks_on(top(t, b)))
                    .map(|b| (a, b))
            })
        };
        let t = deal_with(|t| pair(t).is_some());
        let (from, to) = pair(&t).unwrap();
        let (card, onto) = (top(&t, from), top(&t, to));
        let mut p = play_with(t, DrawMode::One);
        let start = middle(&p, card);
        assert!(p.pick(start, true), "the top card picks up");
        let aim = middle(&p, onto);
        assert!(
            p.hold_at(Point::new(aim.x, aim.y + p.lay.ch * 0.25)),
            "hovering the column lights it"
        );
        let Action::Moved(_) = p.release() else {
            panic!("the drop lands");
        };
        assert_eq!(p.model.table.tableau[to].last(), Some(&card));
        settle(&mut p);
    }

    #[test]
    fn a_drop_off_every_pile_flies_back_and_changes_nothing() {
        let t = Table::deal(5);
        let card = top(&t, 6);
        let mut p = play_with(t.clone(), DrawMode::One);
        assert!(p.pick(middle(&p, card), false));
        p.hold_at(Point::new(4.0, SIZE.height - 4.0));
        assert!(matches!(p.release(), Action::Refused));
        assert_eq!(p.model.table, t);
        assert!(
            p.fx.flights.iter().any(|f| f.card == card.0),
            "it flies back"
        );
        settle(&mut p);
    }

    #[test]
    fn keys_pick_a_column_place_it_and_turn_the_stock() {
        let pair = |t: &Table| {
            (0..COLS).find_map(|a| {
                (0..COLS)
                    .find(|&b| b != a && top(t, a).stacks_on(top(t, b)))
                    .map(|b| (a, b))
            })
        };
        let t = deal_with(|t| pair(t).is_some());
        let (from, to) = pair(&t).unwrap();
        let mut p = play_with(t, DrawMode::Three);
        let digit = |c: usize| ((b'1' + c as u8) as char).to_string();
        assert!(matches!(p.key(&digit(from)), Action::Picked));
        assert!(matches!(p.key(&digit(to)), Action::Moved(_)));
        let Action::Drew(out) = p.key("0") else {
            panic!("0 turns the stock");
        };
        assert_eq!(out.drew, 3);
        assert!(matches!(p.key("Backspace"), Action::Undone));
        assert_eq!(p.model.table.waste.len(), 0);
        settle(&mut p);
    }

    #[test]
    fn a_tap_on_the_stock_turns_it_and_undo_flies_the_card_back() {
        let t = Table::deal(9);
        let mut p = play_with(t.clone(), DrawMode::One);
        let at = center(p.lay.card(p.lay.stock));
        assert!(matches!(p.tap(at), Action::Drew(_)));
        settle(&mut p);
        assert!(p.undo());
        assert!(!p.fx.flights.is_empty());
        settle(&mut p);
        assert_eq!(p.model.table, t);
    }

    #[test]
    fn a_win_finishes_itself_then_bounces_every_card_away() {
        // Everything home but three kings, each alone in a column.
        let mut t = Table::default();
        for s in 0..4u8 {
            let top = if s == 3 { 13 } else { 12 };
            t.foundations[s as usize] = (1..=top).map(|r| Card::new(s, r)).collect();
        }
        for s in 0..3u8 {
            t.tableau[s as usize] = vec![Card::new(s, 13)];
        }
        assert!(t.valid());
        let mut p = play_with(t, DrawMode::One);
        let (mut won, mut over) = (0, 0);
        for _ in 0..1200 {
            let tick = p.step(1.0 / 60.0);
            won += usize::from(tick.won);
            over += usize::from(tick.cascade_over);
        }
        assert!(p.model.won);
        assert_eq!((won, over), (1, 1), "one fanfare, one results card");
        assert_eq!(p.fx.cascade.as_ref().map(|c| c.launched), Some(52));
    }

    #[test]
    fn a_shuffle_deals_a_proven_deal() {
        let mut p = play_with(Table::deal(1), DrawMode::One);
        p.shuffle(DrawMode::Three, 15, true);
        let mut dealt = false;
        for _ in 0..3000 {
            if p.step(1.0 / 60.0).dealt {
                dealt = true;
                break;
            }
        }
        assert!(dealt && p.model.proven && p.model.mode == DrawMode::Three);
        assert_eq!(p.fx.flights.len(), 28, "the tableau deals out");
        settle(&mut p);
    }

    #[test]
    fn every_card_fits_on_screen_at_every_size() {
        // The longest column there can be: six face down under a whole run.
        let mut t = Table::deal(3);
        let run: Vec<Card> = (1..=13)
            .rev()
            .map(|r| Card::new(if r % 2 == 0 { 0 } else { 1 }, r))
            .collect();
        t.tableau[6] = [t.tableau[6].clone(), run].concat();
        for size in [
            Size::new(360.0, 600.0),
            Size::new(390.0, 760.0),
            Size::new(844.0, 330.0),
            Size::new(720.0, 720.0),
            Size::new(1180.0, 760.0),
            Size::new(1600.0, 1000.0),
        ] {
            let mut p = play_with(t.clone(), DrawMode::Three);
            p.lay = layout(size);
            p.size = size;
            for r in p.rests() {
                let (x, y) = (r.rect.origin.x, r.rect.origin.y);
                assert!(
                    x >= 0.0
                        && y >= 0.0
                        && x + r.rect.size.width <= size.width + 0.01
                        && y + r.rect.size.height <= size.height + 0.01,
                    "{size:?}: {:?}",
                    r.rect
                );
            }
        }
    }

    #[test]
    fn the_scripted_seed_scores_as_the_walkthroughs_assume() {
        // dayscript/solitaire.yaml and games.yaml deal a Turn One game under DAY_GAMES_SEED=15
        // and play these keys: 9 sends the ace of diamonds home and turns up the ace of spades, 9
        // sends that home too, 6 then 3 put the ten of hearts on the jack of spades and turn up a
        // card, and 0 turns the stock. Their assertions are these scores.
        let (t, proven) = DealSearch::new(15, DrawMode::One).finish();
        assert!(proven);
        assert!(
            Solver::new(&t, DrawMode::One, DEAL_LIMITS)
                .run(u64::MAX)
                .is_some_and(|v| matches!(v, Verdict::Winnable(_)))
        );
        let mut p = play_with(Table::deal(1), DrawMode::One);
        p.shuffle(DrawMode::One, 15, true);
        let dealt = (0..3000).any(|_| p.step(1.0 / 60.0).dealt);
        assert!(dealt && p.model.table == t);
        settle(&mut p);
        let mut seen = Vec::new();
        for key in ["9", "9", "6", "3", "0"] {
            p.key(key);
            seen.push(p.model.score);
        }
        assert_eq!(seen, vec![15, 30, 30, 35, 35]);
        assert_eq!(p.model.moves, 4);
        assert_eq!(
            p.model.table.waste.last(),
            Some(&Card::new(1, 5)),
            "the five of hearts turns up"
        );
    }
}
