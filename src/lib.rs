//! Day Games — a [Day](https://daybrite.dev) app of small arcade/puzzle games, one crate each.
//! `root()` is the whole UI, shared by every platform: the phones, the desktops, and the web.
//!
//! The home screen is a wrapping grid of game tiles stretched to the window's width, whose
//! previews are drawn by each game's crate with the SAME rendering code as gameplay. Tapping a tile presents the game in a fullscreen
//! `cover` (docs/cover.md) with an X in the top-leading corner to exit; the games defer the
//! system's edge gestures and disable interactive dismissal so an edge swipe mid-game doesn't
//! leave the game. Each game saves its state through `gamekit` when the cover closes or the
//! app is backgrounded, and restores it the next time it opens.

use day::prelude::*;

// Entry point for the mobile, macOS, and web hosts; a desktop binary enters through src/main.rs.
day::day_start!(options: window(), root);

/// Options for every window. The locale catalog and title go to `launch`, which installs them
/// (https://daybrite.dev/docs/localization).
pub fn window() -> day::WindowOptions {
    day::WindowOptions {
        locales: Some((res::locales::DEFAULT, res::locales::CATALOG)),
        title_fn: Some(|| res::str::app_title().format()),
        // Desktop only; phones fill the screen. Tall enough for the Sudoku board and keypad.
        size: day::prelude::Size::new(720.0, 780.0),
        ..Default::default()
    }
}

// Typed names for everything under `resource/` (https://daybrite.dev/docs/resources).
day::resources!();

day::routes! {
    /// The app's games, typed: each variant's key is what deep links, dayscript, and
    /// `current_route()` speak.
    pub(crate) enum Section {
        BlockBlast => "blockblast",
        Breakout => "breakout",
        Charades => "charades",
        Mines => "mines",
        Reversi => "reversi",
        Pipes => "pipes",
        Sirtet => "sirtet",
        Solitaire => "solitaire",
        Sudoku => "sudoku",
        Game2048 => "twentyfortyeight",
    }
}

/// Home-screen palette: a deep night background with translucent tile cards (the
/// Faire-Games look).
const HOME_BG: Color = Color::hex(0x10_10_24);
/// The narrowest a tile's preview gets. The home grid stretches its columns across the window,
/// so previews grow from here; this floor still fits two tiles to a line on a 360pt phone.
const TILE_MIN: f64 = 126.0;

/// Each game's own surface color — painted edge-to-edge behind the presented cover.
fn game_background(section: Section) -> Color {
    match section {
        Section::BlockBlast => blockblast::SURFACE,
        Section::Breakout => breakout::SURFACE,
        Section::Charades => charades::SURFACE,
        Section::Mines => mines::SURFACE,
        Section::Reversi => reversi::SURFACE,
        Section::Pipes => pipes::SURFACE,
        Section::Sirtet => sirtet::SURFACE,
        Section::Solitaire => solitaire::SURFACE,
        Section::Sudoku => sudoku::SURFACE,
        Section::Game2048 => twentyfortyeight::SURFACE,
    }
}

pub fn root() -> impl Piece {
    // `day launch --env DAY_GAMES_SEED=<n>` pins every game's RNG, so a dayscript walkthrough
    // meets the same puzzle and layout on every run (dayscript/sudoku.yaml taps cells it knows
    // are empty for seed 15). Unset, each game seeds itself from the clock.
    if let Some(seed) = day::env("DAY_GAMES_SEED").and_then(|s| s.trim().parse::<u64>().ok()) {
        gamekit::set_seed_override(seed);
    }
    let open = Signal::new(None::<Section>);
    zstack((home_page(open), game_cover(open)))
}

/// One home tile: the game's own preview over a translucent card; tapping presents the game.
fn tile(
    open: Signal<Option<Section>>,
    section: Section,
    title: LocalizedText,
    preview: AnyPiece,
    id: &'static str,
) -> impl Piece + use<> {
    let a11y_title = title.format();
    column((
        // Square at whatever width the tile's column gets.
        preview.grow_w().aspect_ratio(1.0).corner_radius(16.0),
        label(title)
            .weight(FontWeight::Semibold)
            .color(Color::WHITE),
    ))
    .spacing(10.0)
    .min_width(TILE_MIN)
    .padding(12.0)
    .background(Color::rgba(1.0, 1.0, 1.0, 0.08))
    .corner_radius(20.0)
    .on_tap(move || open.set(Some(section)))
    .a11y(move |a| a.label(a11y_title))
    .id(id)
    // Last, so the home grid sees a growing cell and stretches its columns to the width.
    .grow_w()
}

fn home_page(open: Signal<Option<Section>>) -> impl Piece {
    scroll(
        column((
            label(res::str::app_title())
                .font(Font::Title)
                .bold()
                .color(Color::WHITE),
            // As many columns as the narrowest tile allows, stretched to the window's width and
            // re-flowed as it resizes, so a new game is one more tile and never a layout change.
            row((
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
                tile(
                    open,
                    Section::BlockBlast,
                    res::str::nav_blockblast(),
                    blockblast::blockblast_preview(),
                    "tile-blockblast",
                ),
                tile(
                    open,
                    Section::Solitaire,
                    res::str::nav_solitaire(),
                    solitaire::solitaire_preview(),
                    "tile-solitaire",
                ),
                tile(
                    open,
                    Section::Charades,
                    res::str::nav_charades(),
                    charades::charades_preview(),
                    "tile-charades",
                ),
                tile(
                    open,
                    Section::Pipes,
                    res::str::nav_pipes(),
                    pipes::pipes_preview(),
                    "tile-pipes",
                ),
                tile(
                    open,
                    Section::Reversi,
                    res::str::nav_reversi(),
                    reversi::reversi_preview(),
                    "tile-reversi",
                ),
                tile(
                    open,
                    Section::Mines,
                    res::str::nav_mines(),
                    mines::mines_preview(),
                    "tile-mines",
                ),
            ))
            .spacing(16.0)
            .fit(RowFit::WrapColumns { run_spacing: 16.0 }),
        ))
        .spacing(20.0)
        .align(HAlign::Leading)
        .padding(20.0),
    )
    .grow()
    .background(HOME_BG)
    .id("home")
}

/// The fullscreen game surface: the game page shielded from system edge gestures and
/// interactive dismissal, with a small X (top leading) as the one way out.
fn game_cover(open: Signal<Option<Section>>) -> impl Piece {
    cover(open, move |section: &Section| {
        let section = *section;
        // The header draws in ink that contrasts with the game's own surface: white on the dark
        // boards, near-black on 2048's cream one. Set BEFORE the page is built — a title's ink is
        // resolved as its piece is made, not when it draws.
        gamekit::chrome::set_surface(game_background(section));
        let game = match section {
            Section::BlockBlast => blockblast::blockblast_page(),
            Section::Breakout => breakout::breakout_page(),
            Section::Charades => charades::charades_page(),
            Section::Mines => mines::mines_page(),
            Section::Reversi => reversi::reversi_page(),
            Section::Pipes => pipes::pipes_page(),
            Section::Sirtet => sirtet::sirtet_page(),
            Section::Solitaire => solitaire::solitaire_page(),
            Section::Sudoku => sudoku::sudoku_page(),
            Section::Game2048 => twentyfortyeight::twentyfortyeight_page(),
        };
        // Leaving is the shell's to do, and the button that asks for it sits in the game's own
        // header row (gamekit::chrome::game_header), where it lines up with the title and the
        // pause button. Registered per open cover, and cleared with it.
        gamekit::on_close(move || open.set(None));
        game.grow()
            .defers_system_gestures(Edges::ALL)
            .interactive_dismiss_disabled()
            .any()
    })
    .background(|section| game_background(*section))
}
