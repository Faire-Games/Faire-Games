//! Sudoku — a classic 9×9 with notes, unlimited undo/redo, checkpoints, hints, and
//! per-difficulty best times, following Faire-Games' Sudoku. The board is built with Day's
//! GRID layout (§ docs/grid.md): 9 `grid_row`s of 9 interactive cell canvases, native
//! buttons for the toolbar, and a native action sheet for the difficulty picker. All
//! user-facing strings resolve through Fluent (`tr`, resource/locales/*/app.ftl).

use std::cell::RefCell;
use std::rc::Rc;

use day_fluent::tr;
use day_pieces::prelude::*;

mod model;
use model::{DIFFICULTIES, Difficulty, Model, fmt_time, idx};

/// The prefs key this game's state persists under (gamekit; bump on schema change).
const SAVE_KEY: &str = "sudoku.v1";

const CELL: f64 = 36.0;

// Palette (Faire's sudoku look: light paper board, blue entries, orange provisional).
const BG: Color = Color::hex(0xF7_F4_EC);
const GRID_THIN: Color = Color::hex(0xC9_C3_B6);
const GRID_THICK: Color = Color::hex(0x55_50_46);
const INK_GIVEN: Color = Color::hex(0x2A_26_20);
const INK_USER: Color = Color::hex(0x2B_6C_D4);
const INK_PROVISIONAL: Color = Color::hex(0xE0_7A_1F);
const INK_GIVEUP: Color = Color::hex(0x8A_84_78);
const INK_CONFLICT: Color = Color::hex(0xD0_35_35);
const INK_NOTE: Color = Color::hex(0x77_70_63);
const SEL_BG: Color = Color::hex(0xCF_E0_F7);
const PEER_BG: Color = Color::hex(0xEC_E8_DE);
const SAME_BG: Color = Color::hex(0xF3_E4_B5);
const TEXT_DIM: Color = Color::hex(0x77_70_63);

/// The game's cover surface color (edge-to-edge behind the safe area).
pub const SURFACE: Color = BG;

type Game = Rc<RefCell<Model>>;

/// The difficulty display names, as LITERAL `tr` keys so `day lint` tracks their coverage.
fn difficulty_label(d: Difficulty) -> day_fluent::LocalizedText {
    match d {
        Difficulty::Easy => tr("su_easy"),
        Difficulty::Medium => tr("su_medium"),
        Difficulty::Hard => tr("su_hard"),
        Difficulty::Expert => tr("su_expert"),
    }
}

fn seed() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0x5EED_5EED)
        | 1
}

/// One board cell's full rendering — background, box borders, value or pencil marks —
/// shared by the live board and the home-tile preview.
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
) {
    let (w, h) = (sz.width, sz.height);
    d.fill(Shape::Rect(Rect::new(0.0, 0.0, w, h)), bg);
    // Box borders: thick on 3×3 boundaries and the outer rim, hairline elsewhere.
    let mut line = |r: Rect, thick: bool| {
        d.fill(Shape::Rect(r), if thick { GRID_THICK } else { GRID_THIN });
    };
    let (tl, tt) = (
        if col.is_multiple_of(3) { 1.5 } else { 0.5 },
        if row.is_multiple_of(3) { 1.5 } else { 0.5 },
    );
    line(Rect::new(0.0, 0.0, tl, h), col.is_multiple_of(3));
    line(Rect::new(0.0, 0.0, w, tt), row.is_multiple_of(3));
    if col == 8 {
        line(Rect::new(w - 1.5, 0.0, 1.5, h), true);
    }
    if row == 8 {
        line(Rect::new(0.0, h - 1.5, w, 1.5), true);
    }
    if value != 0 {
        d.text(
            &value.to_string(),
            Point::new(w / 2.0, h / 2.0),
            TextStyle {
                size: h * 0.55,
                color: ink,
                anchor: TextAnchor::Centered,
            },
        );
    } else if notes != 0 {
        for digit in 1..=9u8 {
            if notes & (1 << digit) != 0 {
                let (nc, nr) = (((digit - 1) % 3) as f64, ((digit - 1) / 3) as f64);
                d.text(
                    &digit.to_string(),
                    Point::new(w * (0.5 + nc) / 3.0, h * (0.5 + nr) / 3.0),
                    TextStyle {
                        size: h * 0.26,
                        color: INK_NOTE,
                        anchor: TextAnchor::Centered,
                    },
                );
            }
        }
    }
}

/// The home-grid tile preview: a mini board drawn with the SAME cell renderer and palette
/// as gameplay.
pub fn sudoku_preview() -> AnyPiece {
    canvas(|d, sz| {
        if sz.width < 4.0 || sz.height < 4.0 {
            return;
        }
        d.fill(Shape::Rect(Rect::new(0.0, 0.0, sz.width, sz.height)), BG);
        let side = sz.width.min(sz.height) - 8.0;
        let cell = side / 9.0;
        let (ox, oy) = ((sz.width - side) / 2.0, (sz.height - side) / 2.0);
        // A recognizable half-filled board (row*3+r/3+col pattern, some cells blank).
        d.transformed(Affine::translate(ox, oy), |d| {
            for r in 0..9usize {
                for c in 0..9usize {
                    let v = ((r * 3 + r / 3 + c) % 9 + 1) as u8;
                    let shown = (r + c * 3) % 4 != 1 && (r * 7 + c) % 3 != 2;
                    let ink = if (r + c).is_multiple_of(2) {
                        INK_GIVEN
                    } else {
                        INK_USER
                    };
                    d.transformed(Affine::translate(c as f64 * cell, r as f64 * cell), |d| {
                        draw_cell(
                            d,
                            Size::new(cell, cell),
                            r,
                            c,
                            if shown { v } else { 0 },
                            0,
                            BG,
                            ink,
                        );
                    });
                }
            }
        });
    })
    .any()
}

/// The Sudoku screen.
pub fn sudoku_page() -> AnyPiece {
    let game: Game = Rc::new(RefCell::new(Model::new(seed(), Difficulty::Medium)));
    if let Some(s) = gamekit::restore::<model::SaveState>(SAVE_KEY) {
        game.borrow_mut().apply_save(s);
    }
    gamekit::autosave(SAVE_KEY, {
        let game = game.clone();
        move || game.borrow().save_state()
    });

    // `board` invalidates the cells + toolbar titles on every state edit; `clock` only
    // invalidates the HUD line each second, so the 81 cell bindings stay idle while the
    // timer runs.
    let board = Trigger::new();
    let clock = Trigger::new();

    let header = header_line(game.clone(), board, clock);
    let status = status_line(game.clone(), board);
    let grid_piece = board_grid(game.clone(), board);
    let keypad = keypad_row(game.clone(), board);
    let tools = toolbar(game.clone(), board);

    let ticker = frame_clock({
        let game = game.clone();
        move |dt| {
            let mut g = game.borrow_mut();
            let before = g.elapsed as u64;
            g.tick(dt.as_secs_f64());
            let after = g.elapsed as u64;
            drop(g);
            if before != after {
                clock.notify();
            }
        }
    });

    zstack((
        scroll(
            column((header, status, grid_piece, keypad, tools))
                .spacing(10.0)
                .align(HAlign::Leading)
                .padding(Insets {
                    top: 8.0,
                    leading: 18.0,
                    bottom: 16.0,
                    trailing: 18.0,
                }),
        )
        .grow(),
        ticker,
    ))
    .any()
}

/// Difficulty • elapsed time • hints — indented past the cover's close button.
fn header_line(game: Game, board: Trigger, clock: Trigger) -> AnyPiece {
    let g1 = game.clone();
    let g2 = game.clone();
    let g3 = game;
    row((
        spacer().width(40.0),
        label(move || {
            board.track();
            let g = g1.borrow();
            difficulty_label(g.difficulty).format()
        })
        .font(Font::Headline)
        .color(INK_GIVEN),
        label(move || {
            clock.track();
            fmt_time(g2.borrow().elapsed as u64)
        })
        .font(Font::Headline)
        .color(INK_USER)
        .id("su-time"),
        label(move || {
            board.track();
            let g = g3.borrow();
            match g.hints_remaining {
                -1 => tr("su_hints_unlimited").format(),
                n => tr("su_hints").arg("n", n as f64).format(),
            }
        })
        .font(Font::Subheadline)
        .color(TEXT_DIM),
    ))
    .spacing(14.0)
    .any()
}

/// Solved / revealed / best-time line (empty while playing with no record).
fn status_line(game: Game, board: Trigger) -> AnyPiece {
    label(move || {
        board.track();
        let g = game.borrow();
        if g.complete {
            let t = fmt_time(g.elapsed as u64);
            if g.new_best {
                tr("su_solved_best").arg("time", t).format()
            } else {
                tr("su_solved").arg("time", t).format()
            }
        } else if g.given_up {
            tr("su_revealed").format()
        } else {
            match g.records.best[g.difficulty.index()] {
                0 => String::new(),
                b => tr("su_best").arg("time", fmt_time(b)).format(),
            }
        }
    })
    .font(Font::Subheadline)
    .color(INK_PROVISIONAL)
    .id("su-status")
    .any()
}

/// The 9×9 board: Day's eager grid of interactive cell canvases.
fn board_grid(game: Game, board: Trigger) -> AnyPiece {
    let mut rows = Vec::new();
    for r in 0..9usize {
        let mut cells = Vec::new();
        for c in 0..9usize {
            cells.push(cell_piece(game.clone(), board, r, c));
        }
        rows.push(grid_row(PieceVec(cells)).any());
    }
    grid(PieceVec(rows)).id("su-board").any()
}

fn cell_piece(game: Game, board: Trigger, r: usize, c: usize) -> AnyPiece {
    let i = idx(r, c);
    let draw_game = game.clone();
    canvas(move |d, sz| {
        board.track();
        let g = draw_game.borrow();
        let v = g.values[i];
        let sel = g.selected;
        let bg = if sel == Some(i) {
            SEL_BG
        } else if let Some(s) = sel {
            let same =
                v != 0 && g.values[s] == v && g.difficulty.highlights_same_digit() && !g.locked();
            if same {
                SAME_BG
            } else if Model::is_peer(i, s) {
                PEER_BG
            } else {
                BG
            }
        } else {
            BG
        };
        let ink = if g.has_conflict(i) {
            INK_CONFLICT
        } else if g.original[i] {
            INK_GIVEN
        } else if g.given_up_fill[i] {
            INK_GIVEUP
        } else if g.provisional[i] {
            INK_PROVISIONAL
        } else {
            INK_USER
        };
        draw_cell(d, sz, r, c, v, g.notes[i], bg, ink);
    })
    .on_tap({
        let game = game.clone();
        move || {
            let mut g = game.borrow_mut();
            if !g.locked() {
                g.selected = if g.selected == Some(i) { None } else { Some(i) };
            }
            drop(g);
            board.notify();
        }
    })
    .id(format!("su-cell-{i}"))
    .frame(CELL, CELL)
    .any()
}

/// The digit keys 1–9 (dimmed once all nine of a digit are placed).
fn keypad_row(game: Game, board: Trigger) -> AnyPiece {
    let mut keys = Vec::new();
    for digit in 1..=9u8 {
        let draw_game = game.clone();
        let tap_game = game.clone();
        keys.push(
            canvas(move |d, sz| {
                board.track();
                let g = draw_game.borrow();
                let done = g.placed_count(digit) >= 9;
                let notes = g.notes_mode;
                d.fill(
                    Shape::RoundedRect(Rect::new(1.0, 1.0, sz.width - 2.0, sz.height - 2.0), 6.0),
                    if notes {
                        Color::hex(0xEF_E6_CE)
                    } else {
                        Color::hex(0xEC_E8_DE)
                    },
                );
                d.text(
                    &digit.to_string(),
                    Point::new(sz.width / 2.0, sz.height / 2.0),
                    TextStyle {
                        size: sz.height * 0.5,
                        color: if done { GRID_THIN } else { INK_GIVEN },
                        anchor: TextAnchor::Centered,
                    },
                );
            })
            .on_tap(move || {
                let mut g = tap_game.borrow_mut();
                g.place(digit);
                drop(g);
                board.notify();
            })
            .id(format!("su-key-{digit}"))
            .frame(CELL, 44.0)
            .any(),
        );
    }
    row(PieceVec(keys)).id("su-keypad").any()
}

/// Undo / redo / notes / hint, then checkpoint (or commit + revert) / erase / reveal / new.
fn toolbar(game: Game, board: Trigger) -> AnyPiece {
    let act = move |game: &Game, f: fn(&mut Model)| {
        let game = game.clone();
        move || {
            f(&mut game.borrow_mut());
            board.notify();
        }
    };

    let notes_title = {
        let game = game.clone();
        move || {
            board.track();
            if game.borrow().notes_mode {
                tr("su_notes_on").format()
            } else {
                tr("su_notes").format()
            }
        }
    };

    let row1 = row((
        button(tr("su_undo"))
            .action(act(&game, |g| g.undo()))
            .id("su-undo"),
        button(tr("su_redo"))
            .action(act(&game, |g| g.redo()))
            .id("su-redo"),
        button(notes_title)
            .action(act(&game, |g| {
                if !g.locked() {
                    g.notes_mode = !g.notes_mode;
                }
            }))
            .id("su-notes"),
        button(tr("su_hint"))
            .action(act(&game, |g| {
                g.hint();
            }))
            .id("su-hint"),
    ))
    .spacing(8.0);

    // Checkpoint (or, while one is active, commit + revert).
    let checkpoint = {
        let game_cond = game.clone();
        let game_arm = game.clone();
        when(
            move || {
                board.track();
                game_cond.borrow().checkpoint_active
            },
            move || {
                row((
                    button(tr("su_commit"))
                        .action(act(&game_arm, |g| g.commit_checkpoint()))
                        .id("su-commit"),
                    button(tr("su_revert"))
                        .action(act(&game_arm, |g| g.revert_checkpoint()))
                        .id("su-revert"),
                ))
                .spacing(8.0)
            },
        )
    };
    let checkpoint_enter = {
        let game_cond = game.clone();
        let game_arm = game.clone();
        when(
            move || {
                board.track();
                !game_cond.borrow().checkpoint_active
            },
            move || {
                button(tr("su_checkpoint"))
                    .action(act(&game_arm, |g| g.enter_checkpoint()))
                    .id("su-checkpoint")
            },
        )
    };

    let new_game = {
        let game = game.clone();
        button(tr("su_new"))
            .action(move || {
                let game = game.clone();
                day_core::task(async move {
                    let mut a = Alert::new(tr("su_new_title")).message(tr("su_new_message"));
                    for d in DIFFICULTIES {
                        a = a.button(difficulty_label(d), d);
                    }
                    let choice = a.sheet().cancel(tr("su_cancel")).present().await;
                    if let Some(d) = choice {
                        game.borrow_mut().new_game(d);
                        board.notify();
                    }
                });
            })
            .id("su-new")
    };

    let reveal = {
        let game = game.clone();
        button(tr("su_reveal"))
            .action(move || {
                let game = game.clone();
                day_core::task(async move {
                    if game.borrow().locked() {
                        return;
                    }
                    let sure = Alert::new(tr("su_reveal_title"))
                        .message(tr("su_reveal_message"))
                        .destructive(tr("su_reveal_confirm"), true)
                        .cancel(tr("su_cancel"))
                        .present()
                        .await;
                    if sure == Some(true) {
                        game.borrow_mut().give_up();
                        board.notify();
                    }
                });
            })
            .id("su-reveal")
    };

    let row2 = row((
        checkpoint_enter,
        checkpoint,
        button(tr("su_erase"))
            .action(act(&game, |g| {
                g.erase();
            }))
            .id("su-erase"),
        reveal,
        new_game,
    ))
    .spacing(8.0);

    column((row1, row2))
        .spacing(8.0)
        .align(HAlign::Leading)
        .any()
}
