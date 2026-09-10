//! The chrome every game shares (the Faire-Games shell): the dark card the pause menu, the
//! game-over card, the settings sheet, and the how-to-play sheet sit on; the menu buttons; the
//! pause button and its glyph; the per-game settings record; and the haptic gate. Composed from
//! Day's core pieces, so it renders the same on every toolkit (docs/compose.md).

use day_fluent::LocalizedText;
use day_part_haptics::Haptic;
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

/// The settings every game keeps: haptics on or off, and whether the how-to-play sheet has
/// opened by itself yet. Persisted per game under its own key.
#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
pub struct GameSettings {
    pub vibrations: bool,
    pub instructions_shown: bool,
}

impl Default for GameSettings {
    fn default() -> Self {
        GameSettings {
            vibrations: true,
            instructions_shown: false,
        }
    }
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
