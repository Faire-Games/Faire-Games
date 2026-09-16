//! Pipes: rotate a scrambled network, lock settled tiles, and connect every branch.
use day_fluent::{LocalizedText, tr};
use day_pieces::prelude::*;
use gamekit::chrome::{self, Feedback, Help, Sfx, cues, sfx};
use serde::{Deserialize, Serialize};
use std::cell::{Cell, RefCell};
use std::rc::Rc;
mod model;
use model::{Network, PORTS, SIZES, SaveState};

pub const SURFACE: Color = Color::hex(0x0C202B);
const SAVE: &str = "pipes.v1";
const SETTINGS: &str = "pipes.settings";
const RECORDS: &str = "pipes.records";
const TURN: chrome::Cue = cues::with("sounds/pipes/turn.wav", cues::LIGHT_BEAT);
pub const SOUNDS: &[Sfx] = &[sfx("sounds/pipes/turn.wav")];
const WATER: Color = Color::hex(0x51DACA);
#[derive(Clone, Default, Serialize, Deserialize)]
struct Settings {
    shell: chrome::GameSettings,
}
#[derive(Clone, Default, Serialize, Deserialize)]
struct Records {
    best: [Option<u32>; 3],
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
    network: RefCell<Network>,
    overlay: Signal<Overlay>,
    back: Cell<Overlay>,
    repaint: Trigger,
    cursor: Cell<usize>,
    size: Cell<Size>,
    lock_mode: Signal<bool>,
    size_choice: Signal<usize>,
    sounds: Signal<bool>,
    vibrations: Signal<bool>,
    focus: Signal<bool>,
    // A single quarter-turn animation; input waits until it has landed.
    spinning: Cell<Option<(usize, u8)>>,
    age: Cell<f64>,
    win_age: Cell<f64>,
    records: RefCell<Records>,
}
impl Ui {
    fn cue(&self, c: &chrome::Cue) {
        chrome::cue(
            Feedback {
                sounds: self.sounds.get_untracked(),
                vibrations: self.vibrations.get_untracked(),
            },
            c,
        );
    }
    fn show(&self, kind: Overlay) {
        self.overlay.set(kind);
        self.focus.set(kind == Overlay::None);
        self.cue(&cues::SELECT);
    }
    fn push(&self, kind: Overlay) {
        self.back.set(self.overlay.get_untracked());
        self.show(kind);
    }
    fn pop(&self) {
        self.show(self.back.get());
    }
    fn pause(&self) {
        if self.overlay.get_untracked() == Overlay::None {
            self.show(Overlay::Pause);
        }
    }
    fn active(&self) -> bool {
        self.overlay.get_untracked() == Overlay::None && !self.network.borrow().solved()
    }
    fn refresh(&self) {
        *self.network.borrow_mut() = self.game.borrow().network();
        self.repaint.notify();
    }
    fn act(&self, i: usize, lock: bool) {
        if !self.active() || self.spinning.get().is_some() {
            return;
        }
        if lock {
            if self.game.borrow_mut().toggle_lock(i) {
                self.cue(&cues::TICK);
                self.repaint.notify();
            }
            return;
        }
        let before = self.game.borrow().tiles.get(i).copied();
        if !self.game.borrow_mut().turn(i) {
            self.cue(&cues::WARNING);
            return;
        }
        self.spinning.set(Some((i, before.unwrap())));
        self.age.set(0.0);
        self.cue(&TURN);
        self.refresh();
        if self.network.borrow().solved() {
            self.win_age.set(0.0);
            self.cue(&cues::SUCCESS);
            let g = self.game.borrow();
            let index = SIZES.iter().position(|&n| n == g.size).unwrap();
            let mut records = self.records.borrow_mut();
            records.best[index] =
                Some(records.best[index].map_or(g.moves, |best| best.min(g.moves)));
            gamekit::save(RECORDS, &*records);
        }
    }
    fn restart(&self) {
        self.game.borrow_mut().restart();
        self.reset_ui();
    }
    fn start(&self) {
        *self.game.borrow_mut() = SaveState::new(
            SIZES[self.size_choice.get_untracked().min(2)],
            gamekit::seed(),
        );
        self.reset_ui();
    }
    fn reset_ui(&self) {
        self.cursor.set(0);
        self.spinning.set(None);
        self.win_age.set(0.0);
        self.lock_mode.set(false);
        self.refresh();
        self.show(Overlay::None);
        self.cue(&cues::START);
    }
    fn tick(&self, dt: f64) {
        if self.overlay.get_untracked() != Overlay::None {
            return;
        }
        if self.spinning.get().is_some() {
            self.age.set(self.age.get() + dt);
            if self.age.get() >= 0.16 {
                self.spinning.set(None);
            }
            self.repaint.notify();
        }
        if self.network.borrow().solved() {
            self.win_age.set(self.win_age.get() + dt);
            self.repaint.notify();
            if self.win_age.get() > 1.8 {
                self.show(Overlay::Result);
            }
        }
    }
    fn key(&self, key: &str) {
        if self.overlay.get_untracked() != Overlay::None {
            return;
        }
        let n = self.game.borrow().size;
        let i = self.cursor.get();
        match key {
            "ArrowLeft" => self.cursor.set(i / n * n + (i % n + n - 1) % n),
            "ArrowRight" => self.cursor.set(i / n * n + (i % n + 1) % n),
            "ArrowUp" => self.cursor.set((i + n * n - n) % (n * n)),
            "ArrowDown" => self.cursor.set((i + n) % (n * n)),
            " " | "Enter" | "Return" => self.act(i, false),
            "l" | "L" => self.act(i, true),
            "Escape" | "p" | "P" => self.pause(),
            _ => return,
        }
        self.repaint.notify();
    }
    fn selection(&self) -> String {
        self.repaint.track();
        let g = self.game.borrow();
        let i = self.cursor.get();
        let directions: Vec<_> = PORTS
            .iter()
            .enumerate()
            .filter(|(_, bit)| g.tiles[i] & **bit != 0)
            .map(|(d, _)| tr(["pp_north", "pp_east", "pp_south", "pp_west"][d]).format())
            .collect();
        tr("pp_selection")
            .arg("row", (i / g.size + 1) as f64)
            .arg("column", (i % g.size + 1) as f64)
            .arg("ports", directions.join(", "))
            .arg(
                "state",
                tr(if g.locked[i] {
                    "pp_locked"
                } else {
                    "pp_unlocked"
                })
                .format(),
            )
            .format()
    }
}

pub fn pipes_page() -> AnyPiece {
    let settings = gamekit::restore::<Settings>(SETTINGS).unwrap_or_default();
    let game = gamekit::restore::<SaveState>(SAVE)
        .and_then(SaveState::apply_save)
        .unwrap_or_else(|| SaveState::new(5, gamekit::seed()));
    let ui = Rc::new(Ui {
        network: RefCell::new(game.network()),
        size_choice: Signal::new(SIZES.iter().position(|&n| n == game.size).unwrap()),
        game: RefCell::new(game),
        overlay: Signal::new(Overlay::None),
        back: Cell::new(Overlay::None),
        repaint: Trigger::new(),
        cursor: Cell::new(0),
        size: Cell::new(Size::new(0.0, 0.0)),
        lock_mode: Signal::new(false),
        sounds: Signal::new(settings.shell.sounds),
        vibrations: Signal::new(settings.shell.vibrations),
        focus: Signal::new(true),
        spinning: Cell::new(None),
        age: Cell::new(0.0),
        win_age: Cell::new(0.0),
        records: RefCell::new(gamekit::restore(RECORDS).unwrap_or_default()),
    });
    gamekit::sounds(SOUNDS);
    gamekit::autosave(SAVE, {
        let u = ui.clone();
        move || u.game.borrow().save_state()
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
    let (p, m, c, s, l) = (ui.clone(), ui.clone(), ui.clone(), ui.clone(), ui.clone());
    let header = row((
        spacer().width(44.0),
        chrome::fitted_title(tr("nav_pipes"), 22.0, FontWeight::Heavy, chrome::TEXT).grow_w(),
        chrome::pause_button(tr("gk_pause"), "pp-pause", move || p.pause()),
    ))
    .padding(8.0);
    let stats = row((
        pipe_stat(
            tr("pp_moves"),
            move || {
                m.repaint.track();
                m.game.borrow().moves.to_string()
            },
            Color::WHITE,
            "pp-moves",
        ),
        pipe_stat(
            tr("pp_connected"),
            move || {
                c.repaint.track();
                let net = c.network.borrow();
                format!("{} / {}", net.connected, net.distance.len())
            },
            WATER,
            "pp-connected",
        ),
    ));
    let controls = row((
        label(tr("pp_lock_mode")).color(chrome::TEXT),
        toggle(ui.lock_mode).id("pp-lock-mode"),
    ))
    .spacing(10.0)
    .padding(8.0)
    .width(200.0);
    let content = column((
        header,
        stats,
        label(move || {
            s.repaint.track();
            tr(if s.network.borrow().solved() {
                "pp_solved"
            } else {
                "pp_goal"
            })
            .format()
        })
        .color(chrome::TEXT)
        .align(TextAlign::Center)
        .id("pp-status")
        .padding(8.0),
        board_canvas(ui.clone()),
        label(move || l.selection())
            .font(Font::Caption)
            .color(chrome::TEXT)
            .align(TextAlign::Center)
            .id("pp-selection")
            .padding(6.0),
        controls,
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
// Reserve the value's width so multi-digit tabular counters do not clip on web.
fn pipe_stat<M>(
    caption: LocalizedText,
    value: impl IntoText<M>,
    color: Color,
    id: &'static str,
) -> AnyPiece {
    column((
        label(caption).font(Font::Caption).color(chrome::TEXT_DIM),
        label(value)
            .font(Font::Title2)
            .bold()
            .tabular()
            .color(color)
            .align(TextAlign::Center)
            .id(id)
            .width(120.0),
    ))
    .spacing(2.0)
    .align(HAlign::Center)
    .any()
}
fn board_canvas(ui: Rc<Ui>) -> AnyPiece {
    let (d, t, k) = (ui.clone(), ui.clone(), ui.clone());
    canvas(move |draw, size| {
        d.repaint.track();
        d.size.set(size);
        draw_board(
            draw,
            size,
            &d.game.borrow(),
            &d.network.borrow(),
            Some(d.cursor.get()),
            d.spinning.get(),
            d.age.get(),
            d.win_age.get(),
        );
    })
    .on_tap_at(move |p| {
        if !t.active() {
            return;
        }
        let n = t.game.borrow().size;
        let (x, y, cell) = layout(t.size.get(), n);
        if cell <= 0.0
            || p.x < x
            || p.y < y
            || p.x >= x + cell * n as f64
            || p.y >= y + cell * n as f64
        {
            return;
        }
        let i = ((p.y - y) / cell) as usize * n + ((p.x - x) / cell) as usize;
        t.cursor.set(i);
        t.act(i, t.lock_mode.get_untracked());
        t.repaint.notify();
    })
    .on_key(move |event| k.key(&event.key))
    .focused(ui.focus)
    .a11y(|a| a.label(tr("pp_board_a11y").format()))
    .id("pp-board")
    .grow()
    .any()
}
fn layout(size: Size, n: usize) -> (f64, f64, f64) {
    let side = (size.width.min(size.height) - 16.0).clamp(0.0, 560.0);
    (
        (size.width - side) / 2.0,
        (size.height - side) / 2.0,
        side / n as f64,
    )
}
#[allow(clippy::too_many_arguments)]
fn draw_board(
    d: &mut Draw,
    size: Size,
    g: &SaveState,
    net: &Network,
    cursor: Option<usize>,
    spin: Option<(usize, u8)>,
    age: f64,
    win_age: f64,
) {
    let (ox, oy, cell) = layout(size, g.size);
    if cell <= 4.0 {
        return;
    }
    let n = g.size;
    for i in 0..g.tiles.len() {
        let (x, y) = (ox + (i % n) as f64 * cell, oy + (i / n) as f64 * cell);
        let center = Point::new(x + cell / 2.0, y + cell / 2.0);
        let live = net.distance[i].is_some();
        d.fill(
            Shape::RoundedRect(
                Rect::new(x + 1.0, y + 1.0, cell - 2.0, cell - 2.0),
                cell * 0.1,
            ),
            if live {
                Color::hex(0x163C47)
            } else {
                Color::hex(0x152C39)
            },
        );
        let (mask, angle) = match spin {
            Some((j, old)) if i == j => (
                old,
                std::f64::consts::FRAC_PI_2 * (age / 0.16).clamp(0.0, 1.0),
            ),
            _ => (g.tiles[i], 0.0),
        };
        let color = if live { WATER } else { Color::hex(0x7E97A6) };
        let width = cell * 0.16;
        for (dir, bit) in PORTS.iter().enumerate() {
            if mask & bit == 0 {
                continue;
            }
            let a = dir as f64 * std::f64::consts::FRAC_PI_2 - std::f64::consts::FRAC_PI_2 + angle;
            let end = Point::new(
                center.x + a.cos() * cell * 0.5,
                center.y + a.sin() * cell * 0.5,
            );
            d.stroke(
                Shape::Line(center, end),
                Color::hex(0x071923),
                width + cell * 0.08,
            );
            d.stroke(Shape::Line(center, end), color, width);
        }
        let r = if i == g.tiles.len() / 2 {
            cell * 0.18
        } else {
            cell * 0.11
        };
        d.fill(
            Shape::Ellipse(Rect::new(center.x - r, center.y - r, 2.0 * r, 2.0 * r)),
            if i == g.tiles.len() / 2 {
                chrome::GOLD
            } else {
                color
            },
        );
        if g.tiles[i].count_ones() == 1 {
            d.stroke(
                Shape::Ellipse(Rect::new(center.x - r, center.y - r, 2.0 * r, 2.0 * r)),
                Color::hex(0xDCECF0),
                1.0,
            );
        }
        if net.solved() {
            let max = net
                .distance
                .iter()
                .flatten()
                .copied()
                .max()
                .unwrap_or(1)
                .max(1) as f64;
            let arrival = net.distance[i].unwrap_or(0) as f64 / max;
            let glow = (1.0 - ((win_age - arrival) / 0.3).abs()).max(0.0);
            if glow > 0.0 {
                d.stroke(
                    Shape::RoundedRect(Rect::new(x + 3.0, y + 3.0, cell - 6.0, cell - 6.0), 4.0),
                    Color::WHITE.with_alpha(glow),
                    3.0,
                );
            }
        }
        if g.locked[i] {
            // Small padlock in the corner; its outline conveys locking without color alone.
            let a = cell * 0.22;
            let lx = x + cell - a - 5.0;
            let ly = y + 5.0;
            d.stroke(
                Shape::RoundedRect(Rect::new(lx + a * 0.22, ly, a * 0.56, a * 0.7), a * 0.2),
                chrome::GOLD,
                1.5,
            );
            d.fill(
                Shape::RoundedRect(Rect::new(lx, ly + a * 0.4, a, a * 0.65), a * 0.12),
                chrome::GOLD,
            );
        }
        if cursor == Some(i) {
            d.stroke(
                Shape::RoundedRect(Rect::new(x + 2.0, y + 2.0, cell - 4.0, cell - 4.0), 5.0),
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
            tr("nav_pipes"),
            vec![
                Help::Para(tr("pp_help_goal")),
                Help::Para(tr("pp_help_controls")),
                Help::Para(tr("pp_help_locks")),
                Help::Para(tr("pp_help_keys")),
            ],
            "pp-help-done",
            move || ui.pop(),
        )
        .id("pp-help")
        .any();
    }
    let mut items = Vec::new();
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
                "pp-resume",
                move || u.show(Overlay::None),
            ));
            items.push(action(
                "gk_new_game",
                "pp-new-game",
                chrome::BLUE,
                Overlay::NewGame,
            ));
            let u = ui.clone();
            items.push(chrome::menu_button(
                tr("pp_restart"),
                chrome::AMBER,
                "pp-restart",
                move || u.restart(),
            ));
            items.push(action(
                "gk_settings",
                "pp-settings",
                chrome::SLATE,
                Overlay::Settings,
            ));
            items.push(action(
                "gk_instructions",
                "pp-instructions",
                chrome::INDIGO,
                Overlay::Help,
            ));
            items.push(chrome::menu_button(
                tr("gk_quit"),
                chrome::RED,
                "pp-quit",
                || {
                    nav_back();
                },
            ));
        }
        Overlay::NewGame => {
            items.push(chrome::card_title(tr("gk_new_game"), Color::WHITE));
            items.push(label(tr("pp_size")).color(chrome::TEXT).any());
            items.push(
                picker(
                    vec![
                        tr("pp_small").format(),
                        tr("pp_medium").format(),
                        tr("pp_large").format(),
                    ],
                    ui.size_choice,
                )
                .segmented()
                .id("pp-size")
                .any(),
            );
            let u = ui.clone();
            items.push(chrome::menu_button(
                tr("pp_start"),
                chrome::GREEN,
                "pp-start",
                move || u.start(),
            ));
            let u = ui.clone();
            items.push(chrome::menu_button(
                tr("gk_cancel"),
                chrome::SLATE,
                "pp-cancel",
                move || u.pop(),
            ));
        }
        Overlay::Settings => {
            items.push(chrome::card_title(tr("gk_settings"), Color::WHITE));
            items.push(chrome::setting_row(
                tr("gk_sounds"),
                toggle(ui.sounds).id("pp-sounds").any(),
            ));
            items.push(chrome::setting_row(
                tr("gk_vibrations"),
                toggle(ui.vibrations).id("pp-vibrations").any(),
            ));
            let u = ui.clone();
            items.push(chrome::menu_button(
                tr("gk_done"),
                chrome::GREEN,
                "pp-done",
                move || u.pop(),
            ));
        }
        Overlay::Result => {
            items.push(chrome::card_title(tr("pp_solved"), chrome::GOLD));
            let g = ui.game.borrow();
            let index = SIZES.iter().position(|&n| n == g.size).unwrap();
            items.push(pipe_stat(
                tr("pp_moves"),
                g.moves.to_string(),
                Color::WHITE,
                "pp-final-moves",
            ));
            items.push(pipe_stat(
                tr("pp_best"),
                ui.records.borrow().best[index].map_or_else(|| "—".into(), |m| m.to_string()),
                WATER,
                "pp-best",
            ));
            items.push(action(
                "gk_new_game",
                "pp-play-again",
                chrome::GREEN,
                Overlay::NewGame,
            ));
            items.push(chrome::menu_button(
                tr("gk_quit"),
                chrome::SLATE,
                "pp-result-quit",
                || {
                    nav_back();
                },
            ));
        }
        _ => {}
    }
    let id = match kind {
        Overlay::Pause => "pp-pause-menu",
        Overlay::NewGame => "pp-new-card",
        Overlay::Settings => "pp-settings-card",
        _ => "pp-result",
    };
    chrome::card(column(PieceVec(items)).spacing(12.0).align(HAlign::Center))
        .id(id)
        .any()
}
pub fn pipes_preview() -> AnyPiece {
    let mut g = SaveState::new(5, 15);
    g.tiles = model::solution(5, 15);
    // A few disconnected branches show both states on the home tile.
    for i in [0, 4, 20, 24] {
        g.tiles[i] = model::rotate(g.tiles[i]);
    }
    let net = g.network();
    canvas(move |d, size| {
        d.fill(
            Shape::Rect(Rect::new(0.0, 0.0, size.width, size.height)),
            SURFACE,
        );
        draw_board(d, size, &g, &net, None, None, 1.0, 2.0);
    })
    .grow()
    .any()
}
