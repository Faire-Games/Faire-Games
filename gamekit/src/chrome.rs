//! The chrome every game shares (the Faire-Games shell): the dark card the pause menu, the
//! game-over card, the settings sheet, and the how-to-play sheet sit on; the menu buttons; the
//! pause button and its glyph; the per-game settings record; and the haptic gate. Composed from
//! Day's core pieces, so it renders the same on every toolkit (docs/compose.md).

use day_fluent::LocalizedText;
use day_part_haptics::Haptic;
use day_part_sound::{AssetName, Play};
use day_pieces::prelude::*;
use day_spec::{LineCap, LineJoin, StrokeStyle};
use serde::{Deserialize, Serialize};

/// The card surface the overlays sit on.
pub const CARD: Color = Color::rgb(0.08, 0.08, 0.18);
/// The dimming scrim behind a card.
pub const SCRIM: Color = Color::rgba(0.0, 0.0, 0.0, 0.72);
pub const TEXT: Color = Color::rgba(1.0, 1.0, 1.0, 0.85);
pub const TEXT_DIM: Color = Color::rgba(1.0, 1.0, 1.0, 0.55);
pub const GOLD: Color = Color::rgb(1.0, 0.84, 0.25);
// Menu button tints (Faire's pause menu).
pub const GREEN: Color = Color::rgb(0.30, 0.70, 0.40);
pub const BLUE: Color = Color::rgb(0.30, 0.55, 0.95);
pub const SLATE: Color = Color::rgb(0.30, 0.40, 0.60);
pub const INDIGO: Color = Color::rgb(0.40, 0.40, 0.70);
pub const AMBER: Color = Color::rgb(0.70, 0.40, 0.10);
pub const RED: Color = Color::rgb(0.85, 0.30, 0.30);

/// One fixed width for every menu button, so a stack of them lines up.
pub const MENU_W: f64 = 180.0;

/// The settings every game keeps: sounds and haptics on or off, and whether the how-to-play sheet
/// has opened by itself yet. Persisted per game under its own key.
#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
pub struct GameSettings {
    /// On by default, and on for a record saved before sounds existed.
    #[serde(default = "on")]
    pub sounds: bool,
    pub vibrations: bool,
    pub instructions_shown: bool,
}

/// The default for a switch that starts on.
pub fn on() -> bool {
    true
}

impl Default for GameSettings {
    fn default() -> Self {
        GameSettings {
            sounds: true,
            vibrations: true,
            instructions_shown: false,
        }
    }
}

/// A sound clip bundled with the app, named by its path under `resource/assets/`.
pub type Sfx = AssetName;

/// A clip by path, for a `const`: `sfx("sounds/shared/tap.wav")`.
pub const fn sfx(path: &'static str) -> Sfx {
    AssetName::from_static(path)
}

/// What a moment sounds and feels like: a clip, when it starts and how loud, and the haptic phrase
/// it goes with. [`cue`] plays both, each behind its own switch.
pub struct Cue {
    pub sound: Option<Sfx>,
    /// Milliseconds after the phrase's start that the clip starts: 0 for most, later when the
    /// phrase itself waits (a game-over sound timed to a sweep).
    pub sound_at: u32,
    pub volume: f32,
    pub haptic: Pattern,
}

/// A game's two feedback switches, read as a cue fires.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Feedback {
    pub sounds: bool,
    pub vibrations: bool,
}

/// Play `c`: its phrase when vibrations are on, its clip when sounds are.
pub fn cue(fb: Feedback, c: &Cue) {
    haptic_pattern(fb.vibrations, c.haptic);
    if let Some(clip) = &c.sound {
        sound_after(fb.sounds, clip, c.volume, c.sound_at);
    }
}

/// Play `clip` at `volume` when sounds are on.
pub fn sound(enabled: bool, clip: &Sfx, volume: f32) {
    if enabled {
        day_part_sound::play_with(clip, Play::at(volume));
    }
}

/// Play `clip` at `volume` after `delay_ms`, when sounds are on.
pub fn sound_after(enabled: bool, clip: &Sfx, volume: f32, delay_ms: u32) {
    if !enabled {
        return;
    }
    if delay_ms == 0 {
        sound(true, clip, volume);
        return;
    }
    let clip = clip.clone();
    day_core::task(async move {
        day_core::sleep(delay_ms).await;
        day_part_sound::play_with(&clip, Play::at(volume));
    });
}

/// The shared cues: the shell's own sounds and the ones several games share. Each game adds its
/// own beside these.
pub mod cues {
    use super::{Cue, Haptic, Pattern, Sfx, sfx};

    pub const TICK_BEAT: Pattern = &[(0, Haptic::Selection)];
    pub const LIGHT_BEAT: Pattern = &[(0, Haptic::Light)];
    pub const MEDIUM_BEAT: Pattern = &[(0, Haptic::Medium)];
    pub const HEAVY_BEAT: Pattern = &[(0, Haptic::Heavy)];
    pub const SUCCESS_BEAT: Pattern = &[(0, Haptic::Success)];
    pub const WARNING_BEAT: Pattern = &[(0, Haptic::Warning)];

    /// The clip at `path` at full volume, starting with `haptic`.
    pub const fn with(path: &'static str, haptic: Pattern) -> Cue {
        Cue {
            sound: Some(sfx(path)),
            sound_at: 0,
            volume: 1.0,
            haptic,
        }
    }

    /// Pause, a menu choice.
    pub static SELECT: Cue = with("sounds/shared/select.wav", TICK_BEAT);
    /// A value passing a detent: a snap, a step, a moved selection.
    pub static TICK: Cue = with("sounds/shared/tick.wav", TICK_BEAT);
    pub static TAP: Cue = with("sounds/shared/tap.wav", LIGHT_BEAT);
    pub static PLUCK: Cue = with("sounds/shared/pluck.wav", LIGHT_BEAT);
    /// A new game or level.
    pub static START: Cue = with("sounds/shared/start.wav", MEDIUM_BEAT);
    pub static SUCCESS: Cue = with("sounds/shared/success.wav", SUCCESS_BEAT);
    /// A refused move.
    pub static WARNING: Cue = with("sounds/shared/warning.wav", WARNING_BEAT);
    pub static HINT: Cue = with("sounds/shared/hint.wav", TICK_BEAT);
    pub static THUD: Cue = with("sounds/shared/thud.wav", super::THUD);
    pub static LETDOWN: Cue = with("sounds/shared/letdown.wav", super::LETDOWN);
    pub static OVER_ARCADE: Cue = with("sounds/shared/over_arcade.wav", super::GAME_OVER);
    pub static OVER_PUZZLE: Cue = with("sounds/shared/over_puzzle.wav", super::GAME_OVER);

    /// Every shared clip, for preloading and for the app's check that each one is bundled.
    pub const SHARED: &[Sfx] = &[
        sfx("sounds/shared/select.wav"),
        sfx("sounds/shared/tick.wav"),
        sfx("sounds/shared/tap.wav"),
        sfx("sounds/shared/pluck.wav"),
        sfx("sounds/shared/start.wav"),
        sfx("sounds/shared/success.wav"),
        sfx("sounds/shared/warning.wav"),
        sfx("sounds/shared/hint.wav"),
        sfx("sounds/shared/thud.wav"),
        sfx("sounds/shared/letdown.wav"),
        sfx("sounds/shared/over_arcade.wav"),
        sfx("sounds/shared/over_puzzle.wav"),
    ];
}

/// Play `h` when the game's Vibrations setting allows it and the platform has an engine.
pub fn haptic(enabled: bool, h: Haptic) {
    if enabled && day_part_haptics::is_supported() {
        day_part_haptics::play(h);
    }
}

/// A haptic phrase: `(delay in ms from the start, style)` beats, played in order. Day's
/// engine plays one style at a time, so a phrase is what turns a single tick into a
/// celebration or a letdown.
pub type Pattern = &'static [(u32, Haptic)];

/// A clean win: a rising three-beat.
pub const CELEBRATE: Pattern = &[
    (0, Haptic::Success),
    (120, Haptic::Light),
    (240, Haptic::Medium),
];
/// The big one: a level cleared, four lines at once, the 2048 tile.
pub const BIG_CELEBRATE: Pattern = &[
    (0, Haptic::Success),
    (100, Haptic::Light),
    (200, Haptic::Medium),
    (300, Haptic::Heavy),
    (460, Haptic::Success),
];
/// A setback that is not the end: a life lost, a checkpoint thrown away.
pub const LETDOWN: Pattern = &[(0, Haptic::Error), (160, Haptic::Heavy)];
/// The game ending: two slow thuds and a final buzz.
pub const GAME_OVER: Pattern = &[
    (0, Haptic::Heavy),
    (150, Haptic::Heavy),
    (320, Haptic::Error),
];
/// A firm double tap: a piece locking, a heavy merge.
pub const THUD: Pattern = &[(0, Haptic::Heavy), (60, Haptic::Medium)];

/// Play `pattern` when the game's Vibrations setting allows it: the first beat now, the rest
/// on the UI thread after their delays.
pub fn haptic_pattern(enabled: bool, pattern: Pattern) {
    if !enabled || !day_part_haptics::is_supported() {
        return;
    }
    let Some((&(first_at, first), rest)) = pattern.split_first() else {
        return;
    };
    if first_at == 0 {
        day_part_haptics::play(first);
    }
    let later: Vec<(u32, Haptic)> = if first_at == 0 {
        rest.to_vec()
    } else {
        pattern.to_vec()
    };
    if later.is_empty() {
        return;
    }
    day_core::task(async move {
        let mut elapsed = 0u32;
        for (at, h) in later {
            if at > elapsed {
                day_core::sleep(at - elapsed).await;
                elapsed = at;
            }
            day_part_haptics::play(h);
        }
    });
}

pub fn canvas_font(weight: FontWeight) -> CanvasFont {
    CanvasFont {
        family: None,
        weight: Some(weight),
        italic: false,
    }
}

/// The largest size, up to `size`, at which `text` drawn in `font` is no wider than `width`: a
/// canvas line's shrink-to-fit, so a long score or a long translation narrows instead of running
/// into its neighbor.
pub fn fit_text(text: &str, size: f64, font: &CanvasFont, width: f64) -> f64 {
    let wide = day_core::measure_text(text, size, font).width;
    if wide <= width || wide <= 0.0 {
        size
    } else {
        (size * width.max(0.0) / wide).max(1.0)
    }
}

/// Below this, a fitted title steps aside rather than draw text too small to read.
const LEGIBLE: f64 = 10.0;

/// A one-line title for a header it shares with scores and buttons: drawn at `size` when the row
/// leaves it room, narrowed to fit when it does not, and left out once that would take it below a
/// legible size. A label in that spot wraps or ellipsizes instead, one letter per line at worst.
/// Give it `.grow_w()` so it takes what the row has left.
pub fn fitted_title(text: LocalizedText, size: f64, weight: FontWeight, color: Color) -> AnyPiece {
    let spoken = text.format();
    canvas(move |d, sz| {
        let s = text.format();
        let font = canvas_font(weight);
        let fit = fit_text(&s, size, &font, sz.width).min(sz.height * 0.75);
        if fit >= LEGIBLE {
            d.text(
                &s,
                Point::new(sz.width / 2.0, sz.height / 2.0),
                TextStyle {
                    size: fit,
                    color,
                    anchor: TextAnchor::CENTERED,
                    font,
                },
            );
        }
    })
    .a11y(move |a| a.label(spoken.clone()))
    .height(size * 1.5)
    .any()
}

/// A round stroke style `size` points across.
pub fn stroke_style(size: f64) -> StrokeStyle {
    StrokeStyle {
        width: (size * 0.12).max(1.5),
        cap: LineCap::Round,
        join: LineJoin::Round,
        ..Default::default()
    }
}

/// The pause-circle glyph, centered at `c` in a `size`-point square.
pub fn draw_pause_glyph(d: &mut Draw, c: Point, size: f64, color: Color) {
    let s = size / 2.0;
    let style = stroke_style(size);
    let p = |x: f64, y: f64| Point::new(c.x + x * s, c.y + y * s);
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

/// A check mark, centered at `c` in a `size`-point square.
pub fn draw_check_glyph(d: &mut Draw, c: Point, size: f64, color: Color) {
    let s = size / 2.0;
    let p = |x: f64, y: f64| Point::new(c.x + x * s, c.y + y * s);
    d.stroke_styled(
        PathBuilder::new()
            .move_to(p(-0.8, 0.05))
            .line_to(p(-0.25, 0.65))
            .line_to(p(0.85, -0.6))
            .build(),
        color,
        stroke_style(size),
    );
}

/// A cross, centered at `c` in a `size`-point square.
pub fn draw_cross_glyph(d: &mut Draw, c: Point, size: f64, color: Color) {
    let s = size / 2.0;
    let style = stroke_style(size);
    let p = |x: f64, y: f64| Point::new(c.x + x * s, c.y + y * s);
    d.stroke_styled(
        Shape::Line(p(-0.7, -0.7), p(0.7, 0.7)),
        color,
        style.clone(),
    );
    d.stroke_styled(Shape::Line(p(-0.7, 0.7), p(0.7, -0.7)), color, style);
}

/// The 44-point pause button (a pause circle), for a game's top-trailing corner.
pub fn pause_button(
    a11y: LocalizedText,
    id: &'static str,
    action: impl Fn() + 'static,
) -> AnyPiece {
    canvas(|d, sz| {
        draw_pause_glyph(
            d,
            Point::new(sz.width / 2.0, sz.height / 2.0),
            24.0,
            Color::rgba(1.0, 1.0, 1.0, 0.7),
        );
    })
    .on_tap(action)
    .a11y(move |a| a.label(a11y.format()).role(Role::Button))
    .id(id)
    .frame(44.0, 44.0)
    .any()
}

/// The dimming layer under a card. Absorbs taps so the game underneath never hears them.
pub fn scrim() -> AnyPiece {
    canvas(|d, sz| {
        d.fill(Shape::Rect(Rect::new(0.0, 0.0, sz.width, sz.height)), SCRIM);
    })
    .on_tap(|| {})
    .grow()
    .any()
}

/// The rounded dark card an overlay's content sits on.
pub fn card(content: impl Piece) -> AnyPiece {
    content
        .padding(24.0)
        .background(CARD)
        .corner_radius(20.0)
        .max_width(380.0)
        .any()
}

/// A card's headline: "PAUSED", "GAME OVER".
pub fn card_title(text: LocalizedText, color: Color) -> AnyPiece {
    label(text)
        .font(Font::LargeTitle)
        .weight(FontWeight::Black)
        .color(color)
        .align(TextAlign::Center)
        .any()
}

/// A menu button: filled in `tint`, one fixed width so the stack lines up.
pub fn menu_button(
    title: LocalizedText,
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

/// A caption over a value, centered — the "Score / 1240" block of a results card.
pub fn stat<M>(
    caption: LocalizedText,
    value: impl IntoText<M>,
    font: Font,
    color: Color,
    id: &'static str,
) -> AnyPiece {
    column((
        label(caption).font(Font::Caption).color(TEXT_DIM),
        label(value).font(font).bold().tabular().color(color).id(id),
    ))
    .spacing(2.0)
    .align(HAlign::Center)
    .any()
}

/// A settings card's section heading.
pub fn section_heading(text: LocalizedText) -> AnyPiece {
    label(text)
        .font(Font::Caption)
        .weight(FontWeight::Semibold)
        .color(TEXT_DIM)
        .any()
}

/// A settings row: a title on the leading edge, its control trailing.
pub fn setting_row(title: LocalizedText, control: AnyPiece) -> AnyPiece {
    row((label(title).color(TEXT).grow_w(), control))
        .align(VAlign::Center)
        .width(300.0)
        .any()
}

/// A block of the how-to-play sheet.
pub enum Help {
    Heading(LocalizedText),
    /// A paragraph or bullet; inline markdown for the emphasis.
    Para(LocalizedText),
}

/// The how-to-play sheet: a titled, scrolling column of headings and paragraphs with a Done
/// button at the end. At most fifteen blocks per call (a Day tuple's arity); longer sheets
/// split their blocks across two columns.
pub fn instructions_card(
    title: LocalizedText,
    blocks: Vec<Help>,
    done_id: &'static str,
    on_done: impl Fn() + 'static,
) -> AnyPiece {
    let mut pieces: Vec<AnyPiece> = Vec::with_capacity(blocks.len());
    for block in blocks {
        pieces.push(match block {
            Help::Heading(t) => label(t)
                .font(Font::Headline)
                .color(Color::WHITE)
                .align(TextAlign::Leading)
                .any(),
            Help::Para(t) => label(t)
                .font(Font::Body)
                .color(TEXT)
                .markdown()
                .align(TextAlign::Leading)
                .any(),
        });
    }
    card(
        scroll(
            column((
                label(title).font(Font::Title2).bold().color(Color::WHITE),
                column(PieceVec(pieces))
                    .spacing(10.0)
                    .align(HAlign::Leading),
                button(day_fluent::tr("gk_done"))
                    .prominent()
                    .action(on_done)
                    .id(done_id),
            ))
            .spacing(10.0)
            .align(HAlign::Leading)
            .width(300.0),
        )
        .height(440.0),
    )
}
