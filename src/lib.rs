//! Day Games — a [Day](https://daybrite.dev) app of small arcade/puzzle games, one crate each.
//! `root()` is the whole UI, shared by every platform. Mobile-only (iOS / Android / HarmonyOS).
//!
//! The home screen is a grid of game tiles whose previews are drawn by each game's crate with
//! the SAME rendering code as gameplay. Tapping a tile presents the game in a fullscreen
//! `cover` (docs/cover.md) with an X in the top-leading corner to exit; the games defer the
//! system's edge gestures and disable interactive dismissal so an edge swipe mid-game doesn't
//! leave the game. Each game saves its state through `gamekit` when the cover closes or the
//! app is backgrounded, and restores it the next time it opens.

use day::prelude::*;

/// Typed constants for the files under `resource/`, generated at build time by `day-build` (§18.5).
pub mod res {
    include!(concat!(env!("OUT_DIR"), "/day_resources.rs"));
}

day::routes! {
    /// The app's games, typed: each variant's key is what deep links, dayscript, and
    /// `current_route()` speak.
    pub(crate) enum Section {
        Breakout => "breakout",
        Sirtet => "sirtet",
        Sudoku => "sudoku",
        Game2048 => "twentyfortyeight",
    }
}

/// Home-screen palette: a deep night background with translucent tile cards (the
/// Faire-Games look).
const HOME_BG: Color = Color::hex(0x10_10_24);
const TILE_SPAN: f64 = 132.0;

/// Each game's own surface color — painted edge-to-edge behind the presented cover.
fn game_background(section: Section) -> Color {
    match section {
        Section::Breakout => Color::hex(0x0B_0B_1A),
        Section::Sirtet => Color::hex(0x0A_0A_14),
        Section::Sudoku => sudoku::SURFACE,
        Section::Game2048 => Color::hex(0xFA_F8_EF),
    }
}

pub fn root() -> AnyPiece {
    install_locales(
        "en",
        &[("en", include_str!("../resource/locales/en/app.ftl"))],
    );
    let open = Signal::new(None::<Section>);
    zstack((home_page(open), game_cover(open))).any()
}

/// One home tile: the game's own preview over a translucent card; tapping presents the game.
fn tile(
    open: Signal<Option<Section>>,
    section: Section,
    title: LocalizedText,
    preview: AnyPiece,
    id: &'static str,
) -> AnyPiece {
    let a11y_title = title.format();
    column((
        preview.frame(TILE_SPAN, TILE_SPAN).corner_radius(16.0),
        label(title)
            .weight(FontWeight::Semibold)
            .color(Color::WHITE),
    ))
    .spacing(10.0)
    .padding(12.0)
    .background(Color::rgba(1.0, 1.0, 1.0, 0.08))
    .corner_radius(20.0)
    .on_tap(move || open.set(Some(section)))
    .a11y(move |a| a.label(a11y_title))
    .id(id)
}

fn home_page(open: Signal<Option<Section>>) -> AnyPiece {
    scroll(
        column((
            label(res::str::app_title())
                .font(Font::Title)
                .bold()
                .color(Color::WHITE),
            grid((
                grid_row((
                    tile(
                        open,
                        Section::Breakout,
                        res::str::nav_breakout(),
                        breakout::breakout_preview(),
                        "tile-breakout",
                    ),
                    tile(
                        open,
                        Section::Sirtet,
                        res::str::nav_sirtet(),
                        sirtet::sirtet_preview(),
                        "tile-sirtet",
                    ),
                )),
                grid_row((
                    tile(
                        open,
                        Section::Game2048,
                        res::str::nav_2048(),
                        twentyfortyeight::twentyfortyeight_preview(),
                        "tile-twentyfortyeight",
                    ),
                    tile(
                        open,
                        Section::Sudoku,
                        res::str::nav_sudoku(),
                        sudoku::sudoku_preview(),
                        "tile-sudoku",
                    ),
                )),
            ))
            .spacing(16.0),
        ))
        .spacing(20.0)
        .align(HAlign::Leading)
        .padding(20.0),
    )
    .grow()
    .background(HOME_BG)
    .id("home")
    .any()
}

/// The fullscreen game surface: the game page shielded from system edge gestures and
/// interactive dismissal, with a small X (top leading) as the one way out.
fn game_cover(open: Signal<Option<Section>>) -> AnyPiece {
    cover(open, move |section: &Section| {
        let section = *section;
        let game = match section {
            Section::Breakout => breakout::breakout_page(),
            Section::Sirtet => sirtet::sirtet_page(),
            Section::Sudoku => sudoku::sudoku_page(),
            Section::Game2048 => twentyfortyeight::twentyfortyeight_page(),
        };
        // The gesture, a11y, and id go on the canvas itself (the native view that hit-tests);
        // the 44pt frame is the minimum comfortable touch target.
        let close = canvas(|d, sz| {
            // Draw the circle a bit inside the 44pt hit target.
            let r = sz.width.min(sz.height) * 0.40;
            let (cx, cy) = (sz.width / 2.0, sz.height / 2.0);
            d.fill(
                Shape::Ellipse(Rect::new(cx - r, cy - r, 2.0 * r, 2.0 * r)),
                Color::rgba(0.5, 0.5, 0.55, 0.35),
            );
            let a = r * 0.42;
            let x_col = Color::rgba(1.0, 1.0, 1.0, 0.92);
            d.stroke(
                Shape::Line(Point::new(cx - a, cy - a), Point::new(cx + a, cy + a)),
                x_col,
                2.5,
            );
            d.stroke(
                Shape::Line(Point::new(cx - a, cy + a), Point::new(cx + a, cy - a)),
                x_col,
                2.5,
            );
        })
        .on_tap(move || open.set(None))
        .a11y(|a| a.label(res::str::close_game().format()))
        .id("close-game")
        .frame(44.0, 44.0)
        .padding(8.0);
        game.grow()
            .defers_system_gestures(Edges::ALL)
            .interactive_dismiss_disabled()
            .overlay_aligned(Alignment::TopLeading, close)
            .any()
    })
    .background(|section| game_background(*section))
    .any()
}

// Mobile entry points — each macro expands to nothing off its own platform.
day::ios_main!("Day Games", root);
day::android_main!(root);
day::arkui_main!(root);
