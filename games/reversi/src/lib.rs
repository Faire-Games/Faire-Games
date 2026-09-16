//! Reversi: shared canvas drawing, pure rules, and the standard gamekit shell.
use day_fluent::tr;
use day_pieces::prelude::*;
use gamekit::chrome::{self, Feedback, Help, Sfx, cues, sfx};
use serde::{Deserialize, Serialize};
use std::cell::{Cell, RefCell};
use std::rc::Rc;
mod model;
use model::{Board, SaveState};

pub const SURFACE: Color = Color::hex(0x102822);
const SAVE: &str = "reversi.v1";
const SETTINGS: &str = "reversi.settings";
const PLACE: chrome::Cue = cues::with("sounds/reversi/place.wav", cues::LIGHT_BEAT);
pub const SOUNDS: &[Sfx] = &[sfx("sounds/reversi/place.wav")];

#[derive(Clone, Serialize, Deserialize, Default)]
struct Settings {
    shell: chrome::GameSettings,
}
#[derive(Clone, Copy, PartialEq)]
enum Overlay {
    None,
    Pause,
    NewGame,
    Settings,
    Help,
    Result,
}

struct Ui {
    game: RefCell<SaveState>,
    overlay: Signal<Overlay>,
    back: Cell<Overlay>,
    repaint: Trigger,
    cursor: Cell<usize>,
    size: Cell<Size>,
    // Flips use the pre-move color for their first half, then the new color.
    before: Cell<Board>,
    flipped: Cell<u64>,
    age: Cell<f64>,
    wait: Cell<f64>,
    passed: Cell<bool>,
    last: Cell<Option<usize>>,
    sounds: Signal<bool>,
    vibrations: Signal<bool>,
    focus: Signal<bool>,
    mode: Signal<usize>,
    difficulty: Signal<usize>,
}
impl Ui {
    fn cue(&self, cue: &chrome::Cue) {
        chrome::cue(
            Feedback {
                sounds: self.sounds.get_untracked(),
                vibrations: self.vibrations.get_untracked(),
            },
            cue,
        );
    }
    fn show(&self, overlay: Overlay) {
        self.overlay.set(overlay);
        self.focus.set(overlay == Overlay::None);
        self.cue(&cues::SELECT);
    }
    fn push(&self, overlay: Overlay) {
        self.back.set(self.overlay.get_untracked());
        self.show(overlay);
    }
    fn pop(&self) {
        self.show(self.back.get());
    }
    fn pause(&self) {
        if self.overlay.get_untracked() == Overlay::None {
            self.show(Overlay::Pause);
        }
    }
    fn human_turn(&self) -> bool {
        let g = self.game.borrow();
        g.mode == 1 || g.board.turn
    }
    fn play(&self, square: usize) {
        if self.overlay.get_untracked() != Overlay::None
            || !self.human_turn()
            || self.age.get() < 0.32
        {
            return;
        }
        self.commit(square);
    }
    fn commit(&self, square: usize) {
        let before = self.game.borrow().board;
        let flips = self.game.borrow_mut().board.play(square);
        let Some(flips) = flips else {
            self.cue(&cues::WARNING);
            return;
        };
        let after = self.game.borrow().board;
        self.before.set(before);
        self.flipped.set(flips);
        self.last.set(Some(square));
        self.age.set(0.0);
        self.wait.set(0.0);
        self.passed
            .set(before.turn == after.turn && !after.finished());
        self.cue(&PLACE);
        self.repaint.notify();
    }
    fn start(&self) {
        *self.game.borrow_mut() = SaveState::new(
            self.mode.get_untracked(),
            self.difficulty.get_untracked(),
            gamekit::seed(),
        );
        self.cursor.set(19);
        self.age.set(1.0);
        self.flipped.set(0);
        self.last.set(None);
        self.passed.set(false);
        self.wait.set(0.0);
        self.show(Overlay::None);
        self.cue(&cues::START);
        self.repaint.notify();
    }
    fn tick(&self, dt: f64) {
        if self.overlay.get_untracked() != Overlay::None {
            return;
        }
        if self.age.get() < 0.4 {
            self.age.set(self.age.get() + dt);
            self.repaint.notify();
            return;
        }
        let board = self.game.borrow().board;
        if board.finished() {
            self.show(Overlay::Result);
            self.cue(&cues::OVER_PUZZLE);
        } else if !self.human_turn() {
            self.wait.set(self.wait.get() + dt);
            if self.wait.get() >= 0.45 {
                let choice = self.game.borrow_mut().computer_move();
                if let Some(i) = choice {
                    self.commit(i);
                }
            }
        }
    }
    fn key(&self, key: &str) {
        if self.overlay.get_untracked() != Overlay::None {
            return;
        }
        let i = self.cursor.get();
        match key {
            "ArrowLeft" => self.cursor.set(i / 8 * 8 + (i + 7) % 8),
            "ArrowRight" => self.cursor.set(i / 8 * 8 + (i + 1) % 8),
            "ArrowUp" => self.cursor.set((i + 56) % 64),
            "ArrowDown" => self.cursor.set((i + 8) % 64),
            " " | "Enter" | "Return" => self.play(i),
            "Escape" | "p" | "P" => self.pause(),
            _ => return,
        }
        self.repaint.notify();
    }
    fn selection_text(&self) -> String {
        self.repaint.track();
        let i = self.cursor.get();
        let b = self.game.borrow().board;
        let state = if b.black & (1 << i) != 0 {
            tr("rv_black")
        } else if b.white & (1 << i) != 0 {
            tr("rv_white")
        } else if b.flips(i, b.turn) != 0 {
            tr("rv_legal")
        } else {
            tr("rv_empty")
        };
        tr("rv_selection")
            .arg("column", ((b'A' + (i % 8) as u8) as char).to_string())
            .arg("row", (i / 8 + 1) as f64)
            .arg("state", state.format())
            .format()
    }
    fn status(&self) -> String {
        self.repaint.track();
        let b = self.game.borrow().board;
        if b.finished() {
            return result(b).format();
        }
        let turn = if !self.human_turn() {
            tr("rv_thinking")
        } else if b.turn {
            tr("rv_black_turn")
        } else {
            tr("rv_white_turn")
        };
        if self.passed.get() {
            tr("rv_passed").arg("turn", turn.format()).format()
        } else {
            turn.format()
        }
    }
}
fn result(b: Board) -> day_fluent::LocalizedText {
    match b.count(true).cmp(&b.count(false)) {
        std::cmp::Ordering::Greater => tr("rv_black_wins"),
        std::cmp::Ordering::Less => tr("rv_white_wins"),
        std::cmp::Ordering::Equal => tr("rv_draw"),
    }
}

pub fn reversi_page() -> AnyPiece {
    let settings = gamekit::restore::<Settings>(SETTINGS).unwrap_or_default();
    let game = gamekit::restore::<SaveState>(SAVE)
        .and_then(SaveState::apply_save)
        .unwrap_or_else(|| SaveState::new(0, 1, gamekit::seed()));
    let ui = Rc::new(Ui {
        mode: Signal::new(game.mode),
        difficulty: Signal::new(game.difficulty),
        before: Cell::new(game.board),
        game: RefCell::new(game),
        overlay: Signal::new(Overlay::None),
        back: Cell::new(Overlay::None),
        repaint: Trigger::new(),
        cursor: Cell::new(19),
        size: Cell::new(Size::new(0.0, 0.0)),
        flipped: Cell::new(0),
        age: Cell::new(1.0),
        wait: Cell::new(0.0),
        passed: Cell::new(false),
        last: Cell::new(None),
        sounds: Signal::new(settings.shell.sounds),
        vibrations: Signal::new(settings.shell.vibrations),
        focus: Signal::new(true),
    });
    gamekit::sounds(SOUNDS);
    gamekit::autosave(SAVE, {
        let u = ui.clone();
        move || u.game.borrow().clone()
    });
    gamekit::on_background(SAVE, {
        let u = ui.clone();
        move || u.pause()
    });
    Effect::new({
        let u = ui.clone();
        move || {
            gamekit::save(
                SETTINGS,
                &Settings {
                    shell: chrome::GameSettings {
                        sounds: u.sounds.get(),
                        vibrations: u.vibrations.get(),
                        instructions_shown: true,
                    },
                },
            )
        }
    });
    if !settings.shell.instructions_shown {
        ui.push(Overlay::Help);
    }
    let (p, s, b, w) = (ui.clone(), ui.clone(), ui.clone(), ui.clone());
    let header = row((
        spacer().width(44.0),
        chrome::fitted_title(tr("nav_reversi"), 22.0, FontWeight::Heavy, chrome::TEXT).grow_w(),
        chrome::pause_button(tr("gk_pause"), "rv-pause", move || p.pause()),
    ))
    .padding(8.0);
    let scores = row((
        chrome::stat(
            tr("rv_black"),
            move || {
                b.repaint.track();
                b.game.borrow().board.count(true).to_string()
            },
            Font::Title2,
            Color::WHITE,
            "rv-black-score",
        )
        .width(72.0),
        spacer().width(36.0),
        chrome::stat(
            tr("rv_white"),
            move || {
                w.repaint.track();
                w.game.borrow().board.count(false).to_string()
            },
            Font::Title2,
            Color::WHITE,
            "rv-white-score",
        )
        .width(72.0),
    ))
    .align(VAlign::Center)
    .min_width(180.0);
    let selected = ui.clone();
    let content = column((
        header,
        scores,
        label(move || s.status())
            .color(chrome::TEXT)
            .align(TextAlign::Center)
            .id("rv-status")
            .padding(8.0),
        board_canvas(ui.clone()),
        label(move || selected.selection_text())
            .font(Font::Caption)
            .color(chrome::TEXT)
            .id("rv-selection"),
        label(tr("rv_board_hint"))
            .font(Font::Caption)
            .color(chrome::TEXT_DIM)
            .padding(12.0),
    ))
    .align(HAlign::Center)
    .grow();
    let (c, t) = (ui.clone(), ui.clone());
    let clock = when(
        move || c.overlay.get() == Overlay::None,
        move || {
            let u = t.clone();
            frame_clock(move |dt| u.tick(dt.as_secs_f64().min(0.05)))
        },
    );
    zstack((content, overlays(ui), clock))
        .background(SURFACE)
        .any()
}

fn board_canvas(ui: Rc<Ui>) -> AnyPiece {
    let (d, t, k) = (ui.clone(), ui.clone(), ui.clone());
    canvas(move |draw, size| {
        d.repaint.track();
        d.size.set(size);
        let b = d.game.borrow().board;
        draw_board(
            draw,
            size,
            b,
            d.before.get(),
            d.flipped.get(),
            d.age.get(),
            Some(d.cursor.get()),
            d.last.get(),
            true,
        );
    })
    .on_tap_at(move |p| {
        if t.overlay.get_untracked() != Overlay::None || !t.human_turn() {
            return;
        }
        let (x, y, cell) = board_layout(t.size.get());
        if cell <= 0.0 || p.x < x || p.y < y || p.x >= x + cell * 8.0 || p.y >= y + cell * 8.0 {
            return;
        }
        let i = ((p.y - y) / cell) as usize * 8 + ((p.x - x) / cell) as usize;
        t.cursor.set(i);
        t.play(i);
        t.repaint.notify();
    })
    .on_key(move |event| k.key(&event.key))
    .focused(ui.focus)
    .a11y(|a| a.label(tr("rv_board_a11y").format()))
    .id("rv-board")
    .grow()
    .any()
}
fn board_layout(size: Size) -> (f64, f64, f64) {
    let side = (size.width.min(size.height) - 16.0).clamp(0.0, 560.0);
    (
        (size.width - side) / 2.0,
        (size.height - side) / 2.0,
        side / 8.0,
    )
}
#[allow(clippy::too_many_arguments)]
fn draw_board(
    d: &mut Draw,
    size: Size,
    b: Board,
    before: Board,
    flipped: u64,
    age: f64,
    cursor: Option<usize>,
    last: Option<usize>,
    hints: bool,
) {
    let (ox, oy, cell) = board_layout(size);
    if cell <= 4.0 {
        return;
    }
    d.fill(
        Shape::RoundedRect(
            Rect::new(ox - 4.0, oy - 4.0, cell * 8.0 + 8.0, cell * 8.0 + 8.0),
            10.0,
        ),
        Color::hex(0x456D58),
    );
    for i in 0..64 {
        let (x, y) = (ox + (i % 8) as f64 * cell, oy + (i / 8) as f64 * cell);
        d.fill(
            Shape::Rect(Rect::new(x, y, cell, cell)),
            if (i / 8 + i % 8) % 2 == 0 {
                Color::hex(0x24674F)
            } else {
                Color::hex(0x205E48)
            },
        );
        d.stroke(
            Shape::Rect(Rect::new(x, y, cell, cell)),
            Color::rgba(0.0, 0.0, 0.0, 0.15),
            0.7,
        );
        let bit = 1 << i;
        if (b.black | b.white) & bit != 0 {
            let animating = flipped & bit != 0 && age < 0.32;
            let black = if animating && age < 0.16 {
                before.black & bit != 0
            } else {
                b.black & bit != 0
            };
            let squeeze = if animating {
                (age / 0.32 * std::f64::consts::PI).cos().abs().max(0.06)
            } else {
                1.0
            };
            let diameter = cell * 0.76;
            let width = diameter * squeeze;
            d.fill(
                Shape::Ellipse(Rect::new(
                    x + (cell - diameter) / 2.0,
                    y + (cell - diameter) / 2.0 + cell * 0.06,
                    diameter,
                    diameter,
                )),
                Color::rgba(0.0, 0.0, 0.0, 0.28),
            );
            let disc = Rect::new(
                x + (cell - width) / 2.0,
                y + (cell - diameter) / 2.0,
                width,
                diameter,
            );
            d.fill(
                Shape::Ellipse(disc),
                if black {
                    Color::hex(0x182225)
                } else {
                    Color::hex(0xF4EEDA)
                },
            );
            d.stroke(
                Shape::Ellipse(disc),
                if black {
                    Color::hex(0x485453)
                } else {
                    Color::WHITE
                },
                1.2,
            );
            if last == Some(i) {
                d.fill(
                    Shape::Ellipse(Rect::new(
                        x + cell * 0.45,
                        y + cell * 0.45,
                        cell * 0.1,
                        cell * 0.1,
                    )),
                    chrome::GOLD,
                );
            }
        } else if hints && b.flips(i, b.turn) != 0 {
            let r = cell * 0.12;
            d.fill(
                Shape::Ellipse(Rect::new(
                    x + cell / 2.0 - r,
                    y + cell / 2.0 - r,
                    2.0 * r,
                    2.0 * r,
                )),
                Color::rgba(0.92, 0.94, 0.72, 0.48),
            );
        }
        if cursor == Some(i) {
            d.stroke(
                Shape::RoundedRect(Rect::new(x + 2.0, y + 2.0, cell - 4.0, cell - 4.0), 4.0),
                chrome::GOLD,
                2.0,
            );
        }
    }
}
fn overlays(ui: Rc<Ui>) -> AnyPiece {
    let mut layers = Vec::new();
    let u = ui.clone();
    layers.push(when(move || u.overlay.get() != Overlay::None, chrome::scrim).any());
    for kind in [
        Overlay::Pause,
        Overlay::NewGame,
        Overlay::Settings,
        Overlay::Help,
        Overlay::Result,
    ] {
        let (u, v) = (ui.clone(), ui.clone());
        layers.push(
            when(
                move || u.overlay.get() == kind,
                move || overlay_card(v.clone(), kind),
            )
            .any(),
        );
    }
    zstack(PieceVec(layers)).any()
}
fn overlay_card(ui: Rc<Ui>, kind: Overlay) -> AnyPiece {
    if kind == Overlay::Help {
        return chrome::instructions_card(
            tr("nav_reversi"),
            vec![
                Help::Para(tr("rv_help_rules")),
                Help::Para(tr("rv_help_pass")),
                Help::Para(tr("rv_help_solo")),
                Help::Para(tr("rv_help_keys")),
            ],
            "rv-help-done",
            move || ui.pop(),
        )
        .id("rv-help")
        .any();
    }
    let mut items: Vec<AnyPiece> = Vec::new();
    let action = |key: &'static str, id: &'static str, tint: Color, overlay: Overlay| {
        let u = ui.clone();
        chrome::menu_button(tr(key), tint, id, move || u.push(overlay))
    };
    match kind {
        Overlay::Pause => {
            items.push(chrome::card_title(tr("gk_paused"), Color::WHITE));
            let u = ui.clone();
            items.push(chrome::menu_button(
                tr("gk_resume"),
                chrome::GREEN,
                "rv-resume",
                move || u.show(Overlay::None),
            ));
            items.push(action(
                "gk_new_game",
                "rv-new-game",
                chrome::BLUE,
                Overlay::NewGame,
            ));
            items.push(action(
                "gk_settings",
                "rv-settings",
                chrome::SLATE,
                Overlay::Settings,
            ));
            items.push(action(
                "gk_instructions",
                "rv-instructions",
                chrome::INDIGO,
                Overlay::Help,
            ));
            items.push(chrome::menu_button(
                tr("gk_quit"),
                chrome::RED,
                "rv-quit",
                || {
                    nav_back();
                },
            ));
        }
        Overlay::NewGame => {
            items.push(chrome::card_title(tr("gk_new_game"), Color::WHITE));
            items.push(label(tr("rv_mode")).color(chrome::TEXT).any());
            items.push(
                picker(
                    vec![tr("rv_solo").format(), tr("rv_two_players").format()],
                    ui.mode,
                )
                .segmented()
                .id("rv-mode")
                .any(),
            );
            items.push(label(tr("rv_difficulty")).color(chrome::TEXT).any());
            items.push(
                picker(
                    vec![
                        tr("rv_easy").format(),
                        tr("rv_medium").format(),
                        tr("rv_hard").format(),
                    ],
                    ui.difficulty,
                )
                .segmented()
                .id("rv-difficulty")
                .any(),
            );
            let u = ui.clone();
            items.push(chrome::menu_button(
                tr("rv_start"),
                chrome::GREEN,
                "rv-start",
                move || u.start(),
            ));
            let u = ui.clone();
            items.push(chrome::menu_button(
                tr("gk_cancel"),
                chrome::SLATE,
                "rv-cancel",
                move || u.pop(),
            ));
        }
        Overlay::Settings => {
            items.push(chrome::card_title(tr("gk_settings"), Color::WHITE));
            items.push(chrome::setting_row(
                tr("gk_sounds"),
                toggle(ui.sounds).id("rv-sounds").any(),
            ));
            items.push(chrome::setting_row(
                tr("gk_vibrations"),
                toggle(ui.vibrations).id("rv-vibrations").any(),
            ));
            let u = ui.clone();
            items.push(chrome::menu_button(
                tr("gk_done"),
                chrome::GREEN,
                "rv-done",
                move || u.pop(),
            ));
        }
        Overlay::Result => {
            let b = ui.game.borrow().board;
            items.push(chrome::card_title(result(b), chrome::GOLD));
            items.push(
                label(
                    tr("rv_final_score")
                        .arg("black", f64::from(b.count(true)))
                        .arg("white", f64::from(b.count(false))),
                )
                .color(chrome::TEXT)
                .id("rv-result-score")
                .any(),
            );
            items.push(action(
                "gk_new_game",
                "rv-play-again",
                chrome::GREEN,
                Overlay::NewGame,
            ));
            items.push(chrome::menu_button(
                tr("gk_quit"),
                chrome::SLATE,
                "rv-result-quit",
                || {
                    nav_back();
                },
            ));
        }
        _ => {}
    }
    let id = match kind {
        Overlay::Pause => "rv-pause-menu",
        Overlay::NewGame => "rv-new-card",
        Overlay::Settings => "rv-settings-card",
        _ => "rv-result",
    };
    chrome::card(column(PieceVec(items)).spacing(14.0).align(HAlign::Center))
        .id(id)
        .any()
}

pub fn reversi_preview() -> AnyPiece {
    let mut g = SaveState::new(1, 0, 15);
    for _ in 0..20 {
        if let Some(i) = g.computer_move() {
            g.board.play(i);
        }
    }
    let board = g.board;
    canvas(move |d, size| {
        d.fill(
            Shape::Rect(Rect::new(0.0, 0.0, size.width, size.height)),
            SURFACE,
        );
        draw_board(d, size, board, board, 0, 1.0, None, None, false);
    })
    .grow()
    .any()
}
