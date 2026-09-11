//! Charades — the party game played with a phone on your forehead. One player holds it up, screen
//! facing out, and guesses the word the others describe, act out or hum; a nod (the phone tilted
//! toward the floor) scores it, tipping the head back passes. The accelerometer reads the tilt
//! (model.rs `Tilt`); a device without one, or a player who prefers it, answers with buttons or the
//! keyboard instead. The screen stays awake for the round, and the card turns to stay upright for
//! the other players when the phone is held sideways under a rotation lock. The decks are the word
//! lists under words/, one folder per language (words/README.md).

use std::cell::{Cell, RefCell};
use std::f64::consts::PI;
use std::rc::Rc;
use std::sync::{Arc, Mutex};

use day_fluent::tr;
use day_geometry::Affine;
use day_part_haptics::Haptic;
use day_part_sensors::SensorKind;
use day_part_wakelock::ScreenLock;
use day_pieces::prelude::*;
use day_reactive::Scope;
use gamekit::chrome::cues::{self, with};
use gamekit::chrome::{self, Cue, Feedback, Help, Pattern, Sfx, sfx};

mod model;
use model::{Beat, Deck, Gesture, LENGTHS, Mark, Records, Rotation, Round, Settings, Tilt};

/// The prefs keys this game persists under (gamekit).
const SETTINGS_KEY: &str = "charades.settings";
const RECORDS_KEY: &str = "charades.records";
const ROTATION_KEY: &str = "charades.rotation";

/// The game's cover surface color (edge-to-edge behind the safe area).
pub const SURFACE: Color = Color::rgb(0.10, 0.07, 0.20);
const GREEN: Color = Color::rgb(0.16, 0.68, 0.36);
const ORANGE: Color = Color::rgb(0.96, 0.55, 0.13);
const RED: Color = Color::rgb(0.86, 0.24, 0.30);

/// The deck colors, taken in `model::ORDER`; a deck a locale adds is colored from its id.
const PALETTE: [Color; 12] = [
    Color::rgb(0.20, 0.60, 0.35),
    Color::rgb(0.90, 0.45, 0.20),
    Color::rgb(0.80, 0.25, 0.45),
    Color::rgb(0.25, 0.50, 0.85),
    Color::rgb(0.55, 0.35, 0.80),
    Color::rgb(0.10, 0.60, 0.65),
    Color::rgb(0.85, 0.30, 0.30),
    Color::rgb(0.35, 0.40, 0.75),
    Color::rgb(0.75, 0.55, 0.10),
    Color::rgb(0.45, 0.30, 0.65),
    Color::rgb(0.20, 0.55, 0.55),
    Color::rgb(0.70, 0.35, 0.60),
];

/// "3, 2, 1" before the first card.
const COUNTDOWN: f64 = 3.0;
/// How long the Correct or Pass flash holds the screen before the next card.
const FLASH: f64 = 0.65;
/// How long "Time's up" shows before the results.
const TIME_UP_HOLD: f64 = 1.6;
/// How long the phone has to stay upright on the forehead before the countdown starts.
const UPRIGHT_HOLD: f64 = 0.6;
/// How long tilting waits for a first motion sample before offering the buttons instead.
const NO_MOTION_AFTER: f64 = 2.0;
/// Motion samples waiting for the frame clock; older ones are dropped.
const MOTION_QUEUE: usize = 64;

// Sounds, each with the haptic it plays beside (gamekit::chrome::Cue).
const PASS_BEAT: Pattern = &[(0, Haptic::Warning)];
static CORRECT: Cue = with("sounds/charades/correct.wav", cues::SUCCESS_BEAT);
static PASS: Cue = with("sounds/charades/pass.wav", PASS_BEAT);
static CLOCK: Cue = with("sounds/charades/clock.wav", cues::LIGHT_BEAT);
static TIME_UP: Cue = with("sounds/charades/time_up.wav", chrome::GAME_OVER);
static RESULTS: Cue = with("sounds/charades/results.wav", chrome::CELEBRATE);

/// Every clip this game plays besides the shared ones (gamekit preloads both).
pub const SOUNDS: &[Sfx] = &[
    sfx("sounds/charades/correct.wav"),
    sfx("sounds/charades/pass.wav"),
    sfx("sounds/charades/clock.wav"),
    sfx("sounds/charades/time_up.wav"),
    sfx("sounds/charades/results.wav"),
];

fn deck_color(id: &str) -> Color {
    let i = model::ORDER
        .iter()
        .position(|o| *o == id)
        .unwrap_or_else(|| {
            id.bytes()
                .fold(0usize, |h, b| h.wrapping_mul(31).wrapping_add(b as usize))
        });
    PALETTE[i % PALETTE.len()]
}

fn fmt_clock(secs: f64) -> String {
    let s = secs.ceil() as u32;
    format!("{}:{:02}", s / 60, s % 60)
}

/// `a` moved a fraction `t` of the way toward `b`.
fn blend(a: Color, b: Color, t: f64) -> Color {
    Color::rgba(
        a.r + (b.r - a.r) * t,
        a.g + (b.g - a.g) * t,
        a.b + (b.b - a.b) * t,
        a.a + (b.a - a.a) * t,
    )
}

/// Where the game is: choosing a deck, waiting for the phone to go up, counting in, playing,
/// showing that time ran out, or listing the round's words.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Phase {
    Decks,
    Ready,
    Countdown,
    Play,
    TimeUp,
    Results,
}

impl Phase {
    /// The phases the frame clock runs in.
    fn timed(self) -> bool {
        matches!(
            self,
            Phase::Ready | Phase::Countdown | Phase::Play | Phase::TimeUp
        )
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Overlay {
    None,
    Pause,
    Settings,
    Instructions,
}

/// Accelerometer samples on their way from the sensor's thread to the frame clock.
#[derive(Default)]
struct Motion {
    queue: Vec<[f64; 3]>,
    last: Option<[f64; 3]>,
}

/// The per-frame state of a round in progress.
#[derive(Default)]
struct Stage {
    /// Seconds spent in the current phase.
    in_phase: f64,
    /// Seconds the phone has been upright, while waiting for it to go up.
    upright_for: f64,
    /// The last whole second the countdown showed.
    count_shown: u32,
    /// The answer being flashed, and for how much longer.
    flash: Option<(Mark, f64)>,
    /// The word the flash is for.
    flashed_word: String,
    /// Which way is down on the screen, in quarter turns (model `Tilt::screen_down`).
    quarter: u8,
    /// A motion sample has arrived since the phone went up.
    heard_motion: bool,
}

struct Ui {
    phase: Signal<Phase>,
    overlay: Signal<Overlay>,
    /// Where Done in Settings or the rules returns to.
    return_to: Cell<Overlay>,
    repaint: Trigger,
    /// Fires when a different card shows, for the card's accessibility label.
    card: Trigger,
    sounds: Signal<bool>,
    vibrations: Signal<bool>,
    /// An index into `LENGTHS`.
    length: Signal<usize>,
    tilt_on: Signal<bool>,
    tilt_available: bool,
    locale: &'static str,
    decks: Vec<Deck>,
    records: RefCell<Records>,
    rotation: RefCell<Rotation>,
    deck: RefCell<Option<Deck>>,
    round: RefCell<Option<Round>>,
    round_seed: Cell<u64>,
    stage: RefCell<Stage>,
    motion: Arc<Mutex<Motion>>,
    tilt: RefCell<Tilt>,
    /// This round is answered by tilting (else by the buttons and keys).
    tilting: Signal<bool>,
    lock: RefCell<Option<ScreenLock>>,
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

    fn set_phase(&self, p: Phase) {
        self.stage.borrow_mut().in_phase = 0.0;
        self.phase.set(p);
        self.repaint.notify();
    }

    fn show(&self, o: Overlay) {
        self.overlay.set(o);
        self.repaint.notify();
        if o == Overlay::None {
            self.drop_stale_motion();
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

    /// Samples that queued while nothing was reading them describe a pose long gone.
    fn drop_stale_motion(&self) {
        if let Ok(mut m) = self.motion.lock() {
            m.queue.clear();
        }
    }

    fn pause(&self) {
        if self.overlay.get_untracked() == Overlay::None
            && matches!(
                self.phase.get_untracked(),
                Phase::Ready | Phase::Countdown | Phase::Play
            )
        {
            self.show(Overlay::Pause);
        }
    }

    /// Deal a round from `id` and wait for the phone to go up.
    fn start(&self, id: &str) {
        let Some(deck) = self.decks.iter().find(|d| d.id == id).cloned() else {
            return;
        };
        let seed = gamekit::seed();
        let order = self
            .rotation
            .borrow_mut()
            .deal(self.locale, deck.id, deck.words.len(), seed);
        let words = order.into_iter().map(|i| deck.words[i].clone()).collect();
        let secs = LENGTHS[self.length.get_untracked().min(LENGTHS.len() - 1)];
        *self.round.borrow_mut() = Some(Round::new(words, f64::from(secs)));
        *self.deck.borrow_mut() = Some(deck);
        self.round_seed.set(seed);
        self.new_best.set(false);

        let tilting = self.tilt_on.get_untracked() && self.tilt_available;
        self.tilting.set(tilting);
        {
            let mut tilt = self.tilt.borrow_mut();
            *tilt = Tilt::new(self.motion_sign());
        }
        *self.stage.borrow_mut() = Stage::default();
        self.drop_stale_motion();
        *self.lock.borrow_mut() = Some(day_part_wakelock::keep_screen_on());
        self.set_phase(Phase::Ready);
        self.focus.set(true);
        self.cue(&cues::SELECT);
    }

    /// The accelerometer's sign convention. The web's differs between browsers, so there it is
    /// read from the phone as the deck was tapped, when the player was looking at the screen.
    fn motion_sign(&self) -> f64 {
        let native = model::native_sign();
        if !cfg!(target_arch = "wasm32") {
            return native;
        }
        let last = self.motion.lock().ok().and_then(|m| m.last);
        last.and_then(model::sign_from_face_up).unwrap_or(native)
    }

    fn begin_countdown(&self) {
        self.stage.borrow_mut().count_shown = COUNTDOWN as u32 + 1;
        self.set_phase(Phase::Countdown);
    }

    fn begin_play(&self) {
        self.tilt.borrow_mut().calibrate();
        self.card.notify();
        self.set_phase(Phase::Play);
        self.cue(&cues::START);
    }

    /// Score or pass the card showing.
    fn answer(&self, mark: Mark) {
        if self.phase.get_untracked() != Phase::Play
            || self.overlay.get_untracked() != Overlay::None
            || self.stage.borrow().flash.is_some()
        {
            return;
        }
        let word = {
            let mut round = self.round.borrow_mut();
            let Some(round) = round.as_mut() else { return };
            let word = round.current().map(str::to_string);
            if !round.answer(mark) {
                return;
            }
            word.unwrap_or_default()
        };
        self.card.notify();
        {
            let mut stage = self.stage.borrow_mut();
            stage.flash = Some((mark, FLASH));
            stage.flashed_word = word;
        }
        self.cue(match mark {
            Mark::Correct => &CORRECT,
            Mark::Pass => &PASS,
        });
        self.repaint.notify();
    }

    fn time_up(&self) {
        self.set_phase(Phase::TimeUp);
        self.cue(&TIME_UP);
    }

    /// The round is over: record it, let the screen sleep again, and show what was played.
    fn finish(&self) {
        let (score, used) = match self.round.borrow().as_ref() {
            Some(r) => (r.score() as u32, r.used()),
            None => return,
        };
        if let Some(deck) = self.deck.borrow().as_ref() {
            let best = self.records.borrow_mut().record(deck.id, score);
            self.new_best.set(best && score > 0);
            self.rotation.borrow_mut().commit(
                self.locale,
                deck.id,
                deck.words.len(),
                self.round_seed.get(),
                used,
            );
        }
        gamekit::save(RECORDS_KEY, &*self.records.borrow());
        gamekit::save(ROTATION_KEY, &*self.rotation.borrow());
        self.lock.borrow_mut().take();
        self.stage.borrow_mut().flash = None;
        self.show(Overlay::None);
        self.set_phase(Phase::Results);
        self.cue(&RESULTS);
    }

    fn to_decks(&self) {
        self.lock.borrow_mut().take();
        *self.round.borrow_mut() = None;
        self.show(Overlay::None);
        self.set_phase(Phase::Decks);
    }

    fn key(&self, key: &str) {
        if self.overlay.get_untracked() != Overlay::None {
            return;
        }
        match (self.phase.get_untracked(), key) {
            (Phase::Play, "ArrowDown" | "Enter" | " ") => self.answer(Mark::Correct),
            (Phase::Play, "ArrowUp" | "Backspace") => self.answer(Mark::Pass),
            (Phase::Ready, "Enter" | " ") => self.begin_countdown(),
            (Phase::Play | Phase::Countdown | Phase::Ready, "Escape") => self.pause(),
            _ => {}
        }
    }
}

/// The Charades screen.
pub fn charades_page() -> AnyPiece {
    let settings = gamekit::restore::<Settings>(SETTINGS_KEY).unwrap_or_default();
    let locale = model::resolve_locale(&day_fluent::locale().get_untracked());
    let length = LENGTHS
        .iter()
        .position(|l| *l == settings.round_secs)
        .unwrap_or(1);
    let tilt_available = day_part_sensors::is_available(SensorKind::Accelerometer);
    let ui = Rc::new(Ui {
        phase: Signal::new(Phase::Decks),
        overlay: Signal::new(Overlay::None),
        return_to: Cell::new(Overlay::None),
        repaint: Trigger::new(),
        card: Trigger::new(),
        sounds: Signal::new(settings.sounds),
        vibrations: Signal::new(settings.vibrations),
        length: Signal::new(length),
        tilt_on: Signal::new(settings.tilt),
        tilt_available,
        locale,
        decks: model::decks(locale),
        records: RefCell::new(gamekit::restore(RECORDS_KEY).unwrap_or_default()),
        rotation: RefCell::new(gamekit::restore::<Rotation>(ROTATION_KEY).unwrap_or_default()),
        deck: RefCell::new(None),
        round: RefCell::new(None),
        round_seed: Cell::new(0),
        stage: RefCell::new(Stage::default()),
        motion: Arc::new(Mutex::new(Motion::default())),
        tilt: RefCell::new(Tilt::new(model::native_sign())),
        tilting: Signal::new(false),
        lock: RefCell::new(None),
        new_best: Cell::new(false),
        focus: Signal::new(true),
    });
    gamekit::sounds(SOUNDS);

    // The accelerometer streams while the page is open; the frame clock reads what arrived.
    if tilt_available {
        let motion = ui.motion.clone();
        let watch = day_part_sensors::watch(SensorKind::Accelerometer, move |r| {
            if let Ok(mut m) = motion.lock() {
                if m.queue.len() >= MOTION_QUEUE {
                    m.queue.remove(0);
                }
                m.queue.push([r.x, r.y, r.z]);
                m.last = Some([r.x, r.y, r.z]);
            }
        });
        Scope::current().on_cleanup(move || drop(watch));
    }
    // A round left by closing the game lets the screen sleep again.
    {
        let ui = ui.clone();
        Scope::current().on_cleanup(move || {
            ui.lock.borrow_mut().take();
        });
    }

    Effect::new({
        let ui = ui.clone();
        move || {
            gamekit::save(
                SETTINGS_KEY,
                &Settings {
                    sounds: ui.sounds.get(),
                    vibrations: ui.vibrations.get(),
                    instructions_shown: true,
                    round_secs: LENGTHS[ui.length.get().min(LENGTHS.len() - 1)],
                    tilt: ui.tilt_on.get(),
                },
            );
        }
    });
    if !settings.instructions_shown {
        ui.push(Overlay::Instructions);
    }
    gamekit::on_background(SETTINGS_KEY, {
        let ui = ui.clone();
        move || ui.pause()
    });

    let (du, gu, cu, bu, ru) = (ui.clone(), ui.clone(), ui.clone(), ui.clone(), ui.clone());
    zstack((
        when(
            move || du.phase.get() == Phase::Decks,
            move || deck_screen(gu.clone()),
        ),
        when(
            {
                let u = ui.clone();
                move || u.phase.get().timed()
            },
            {
                let u = ui.clone();
                move || game_screen(u.clone())
            },
        ),
        when(
            {
                let u = ui.clone();
                move || u.phase.get() == Phase::Results
            },
            move || results_screen(ru.clone()),
        ),
        overlays(ui.clone()),
        // Mounted only while a round runs and nothing covers it.
        when(
            move || cu.phase.get().timed() && cu.overlay.get() == Overlay::None,
            move || charades_clock(bu.clone()),
        ),
    ))
    .any()
}

// ---------------------------------------------------------------------------
// Choosing a deck
// ---------------------------------------------------------------------------

fn deck_screen(ui: Rc<Ui>) -> AnyPiece {
    let mut tiles = Vec::with_capacity(ui.decks.len());
    for deck in &ui.decks {
        tiles.push(deck_tile(ui.clone(), deck));
    }
    let (iu, su) = (ui.clone(), ui.clone());
    // The title keeps its own line, clear of the cover's close button, and the two buttons get a
    // row of their own under the intro: sharing one row, a phone gave the title a third of its
    // width.
    let header = row((
        spacer().width(44.0),
        label(tr("nav_charades"))
            .font(Font::Title)
            .bold()
            .color(Color::WHITE)
            .grow_w(),
    ))
    .align(VAlign::Center);
    let tools = row((
        button(tr("gk_instructions"))
            .bordered()
            .tint(Color::WHITE)
            .action(move || iu.push(Overlay::Instructions))
            .id("ch-instructions"),
        button(tr("gk_settings"))
            .bordered()
            .tint(Color::WHITE)
            .action(move || su.push(Overlay::Settings))
            .id("ch-settings"),
    ))
    .spacing(8.0);
    scroll(
        column((
            header,
            label(tr("ch_pick_deck")).color(chrome::TEXT),
            tools,
            row(PieceVec(tiles))
                .spacing(12.0)
                .fit(RowFit::WrapColumns { run_spacing: 12.0 }),
        ))
        .spacing(16.0)
        .align(HAlign::Leading)
        .padding(Insets {
            top: 12.0,
            leading: 16.0,
            bottom: 24.0,
            trailing: 16.0,
        }),
    )
    .grow()
    .background(SURFACE)
    .id("ch-decks")
    .any()
}

fn deck_tile(ui: Rc<Ui>, deck: &Deck) -> AnyPiece {
    let id = deck.id;
    let color = deck_color(id);
    let best = ui.records.borrow().best(id);
    let meta = tr("ch_deck_meta")
        .arg("count", deck.words.len() as f64)
        .arg("best", f64::from(best));
    let a11y = deck.title.clone();
    column((
        label(deck.title.clone())
            .font(Font::Title3)
            .bold()
            .color(Color::WHITE),
        label(deck.blurb.clone())
            .font(Font::Footnote)
            .color(Color::rgba(1.0, 1.0, 1.0, 0.85)),
        label(meta)
            .font(Font::Caption)
            .tabular()
            .color(Color::rgba(1.0, 1.0, 1.0, 0.7)),
    ))
    .spacing(6.0)
    .align(HAlign::Leading)
    .min_width(150.0)
    .padding(14.0)
    .background(color)
    .corner_radius(16.0)
    .on_tap(move || ui.start(id))
    .a11y(move |a| a.label(a11y.clone()).role(Role::Button))
    .id(format!("ch-deck-{id}"))
    // Last, so the wrap sees a growing cell and stretches its columns to the width.
    .grow_w()
    .any()
}

// ---------------------------------------------------------------------------
// The round
// ---------------------------------------------------------------------------

fn game_screen(ui: Rc<Ui>) -> AnyPiece {
    let (du, ku) = (ui.clone(), ui.clone());
    let card = canvas(move |d, sz| {
        du.repaint.track();
        draw_round(&du, d, sz);
    })
    .on_key(move |k| ku.key(&k.key))
    .focused(ui.focus)
    .a11y({
        let u = ui.clone();
        move |a| {
            u.card.track();
            let word = u
                .round
                .borrow()
                .as_ref()
                .and_then(|r| r.current().map(str::to_string))
                .unwrap_or_default();
            a.label(tr("ch_card_a11y").arg("word", word).format())
        }
    })
    .id("ch-canvas")
    .grow();

    // Starting by hand: always there while waiting, since a phone can be held up in a pose the
    // sensor does not call upright.
    let ready = {
        let (c, s, b) = (ui.clone(), ui.clone(), ui.clone());
        when(
            move || c.phase.get() == Phase::Ready && c.overlay.get() == Overlay::None,
            move || {
                let (s, b) = (s.clone(), b.clone());
                row((
                    button(tr("ch_back"))
                        .bordered()
                        .tint(Color::WHITE)
                        .action(move || b.to_decks())
                        .id("ch-back"),
                    button(tr("ch_start"))
                        .prominent()
                        .tint(GREEN)
                        .action(move || s.begin_countdown())
                        .id("ch-start"),
                ))
                .spacing(16.0)
            },
        )
    };
    // The buttons, for a round answered without tilting.
    let answers = {
        let (c, p, k) = (ui.clone(), ui.clone(), ui.clone());
        when(
            move || c.phase.get() == Phase::Play && !c.tilting.get(),
            move || {
                let (p, k) = (p.clone(), k.clone());
                row((
                    button(tr("ch_pass"))
                        .prominent()
                        .tint(ORANGE)
                        .action(move || p.answer(Mark::Pass))
                        .id("ch-pass")
                        .grow_w(),
                    button(tr("ch_correct"))
                        .prominent()
                        .tint(GREEN)
                        .action(move || k.answer(Mark::Correct))
                        .id("ch-correct")
                        .grow_w(),
                ))
                .spacing(16.0)
                .max_width(520.0)
            },
        )
    };
    let pause = {
        let (c, u) = (ui.clone(), ui.clone());
        when(
            move || matches!(c.phase.get(), Phase::Countdown | Phase::Play),
            move || {
                let u = u.clone();
                chrome::pause_button(tr("gk_pause"), "ch-pause", move || u.pause())
            },
        )
    };
    zstack((
        card,
        column((spacer(), ready, answers))
            .spacing(12.0)
            .align(HAlign::Center)
            .padding(Insets {
                top: 0.0,
                leading: 24.0,
                bottom: 28.0,
                trailing: 24.0,
            }),
    ))
    .overlay_aligned(
        Alignment::TopTrailing,
        pause.padding(Insets {
            top: 4.0,
            leading: 0.0,
            bottom: 0.0,
            trailing: 6.0,
        }),
    )
    .background(SURFACE)
    .any()
}

/// The frame consumer: motion into gestures, the countdown, the round's clock, and the flashes.
fn charades_clock(ui: Rc<Ui>) -> impl Piece {
    let sample_dt = day_part_sensors::SAMPLE_MS as f64 / 1000.0;
    frame_clock(move |dt| {
        let dt = dt.as_secs_f64().min(0.1);
        let phase = ui.phase.get_untracked();
        ui.stage.borrow_mut().in_phase += dt;

        // Motion first, so this frame acts on the newest pose.
        let samples = ui
            .motion
            .lock()
            .map(|mut m| std::mem::take(&mut m.queue))
            .unwrap_or_default();
        let mut gestures = Vec::new();
        if ui.tilting.get_untracked() {
            let mut tilt = ui.tilt.borrow_mut();
            for s in &samples {
                gestures.extend(tilt.feed(*s, sample_dt));
            }
            if !samples.is_empty() {
                let mut stage = ui.stage.borrow_mut();
                stage.heard_motion = true;
                if let Some(q) = tilt.screen_down() {
                    stage.quarter = q;
                }
            }
        }

        match phase {
            Phase::Ready => {
                if ui.tilting.get_untracked() {
                    let (upright, heard, waited) = {
                        let stage = ui.stage.borrow();
                        (
                            ui.tilt.borrow().upright(),
                            stage.heard_motion,
                            stage.in_phase,
                        )
                    };
                    if !heard && waited >= NO_MOTION_AFTER {
                        // A sensor that never reports: this round uses the buttons.
                        ui.tilting.set(false);
                    }
                    let mut stage = ui.stage.borrow_mut();
                    stage.upright_for = if upright { stage.upright_for + dt } else { 0.0 };
                    if stage.upright_for >= UPRIGHT_HOLD {
                        drop(stage);
                        ui.begin_countdown();
                    }
                }
            }
            Phase::Countdown => {
                let left = COUNTDOWN - ui.stage.borrow().in_phase;
                if left <= 0.0 {
                    ui.begin_play();
                } else {
                    let whole = left.ceil() as u32;
                    let mut stage = ui.stage.borrow_mut();
                    if whole < stage.count_shown {
                        stage.count_shown = whole;
                        drop(stage);
                        ui.cue(&cues::TICK);
                    }
                }
            }
            Phase::Play => {
                let flashing = {
                    let mut stage = ui.stage.borrow_mut();
                    if let Some((_, t)) = stage.flash.as_mut() {
                        *t -= dt;
                        if *t <= 0.0 {
                            stage.flash = None;
                        }
                    }
                    stage.flash.is_some()
                };
                if !flashing {
                    for g in gestures {
                        ui.answer(match g {
                            Gesture::Down => Mark::Correct,
                            Gesture::Up => Mark::Pass,
                        });
                    }
                }
                let (beat, over) = {
                    let mut round = ui.round.borrow_mut();
                    match round.as_mut() {
                        Some(r) => (r.tick(dt), r.over()),
                        None => (None, false),
                    }
                };
                match beat {
                    Some(Beat::TimeUp) => ui.time_up(),
                    Some(Beat::Warning(_)) => ui.cue(&CLOCK),
                    // The deck ran out: end once the last answer's flash has shown.
                    None if over && ui.stage.borrow().flash.is_none() => ui.time_up(),
                    None => {}
                }
            }
            Phase::TimeUp => {
                if ui.stage.borrow().in_phase >= TIME_UP_HOLD {
                    ui.finish();
                }
            }
            Phase::Decks | Phase::Results => {}
        }
        ui.repaint.notify();
    })
}

/// The size that fits `text` across `w`, no taller than `max`: on one line, or on two when that
/// reads larger. Returns the lines and the size.
fn fit_word(text: &str, w: f64, max: f64) -> (Vec<String>, f64) {
    let font = chrome::canvas_font(FontWeight::Black);
    let per_point = |s: &str| (day_core::measure_text(s, 100.0, &font).width / 100.0).max(0.01);
    let one = (w / per_point(text)).min(max);
    let split = text
        .char_indices()
        .filter(|(_, c)| *c == ' ')
        .map(|(i, _)| i)
        .min_by_key(|i| (text.len() as isize / 2 - *i as isize).abs());
    if let Some(at) = split
        && one < max * 0.6
    {
        let (a, b) = (text[..at].trim(), text[at..].trim());
        let two = (w / per_point(a)).min(w / per_point(b)).min(max * 0.8);
        if two > one * 1.15 {
            return (vec![a.to_string(), b.to_string()], two);
        }
    }
    (vec![text.to_string()], one)
}

fn centered(d: &mut Draw, text: &str, at: Point, size: f64, color: Color, weight: FontWeight) {
    d.text(
        text,
        at,
        TextStyle {
            size,
            color,
            anchor: TextAnchor::CENTERED,
            font: chrome::canvas_font(weight),
        },
    );
}

/// Draw the round at `sz`. When the phone is held sideways but the screen stayed portrait (a
/// rotation lock), everything turns a quarter so the other players read it upright.
fn draw_round(ui: &Ui, d: &mut Draw, sz: Size) {
    let phase = ui.phase.get_untracked();
    let stage = ui.stage.borrow();
    let deck_tint = ui
        .deck
        .borrow()
        .as_ref()
        .map(|dk| deck_color(dk.id))
        .unwrap_or(PALETTE[0]);
    let flash = stage.flash.map(|(m, _)| m);
    let bg = match (phase, flash) {
        (Phase::Play, Some(Mark::Correct)) => GREEN,
        (Phase::Play, Some(Mark::Pass)) => ORANGE,
        (Phase::TimeUp, _) => RED,
        _ => deck_tint,
    };
    d.fill(
        Shape::Rect(Rect::new(0.0, 0.0, sz.width, sz.height)),
        RadialGradient::new(
            UnitPoint::CENTER,
            0.9,
            vec![(0.0, bg), (1.0, blend(bg, SURFACE, 0.45))],
        ),
    );

    let quarter = if ui.tilting.get_untracked() && sz.width < sz.height {
        stage.quarter
    } else {
        0
    };
    let (w, h) = if quarter % 2 == 1 {
        (sz.height, sz.width)
    } else {
        (sz.width, sz.height)
    };
    let (cx, cy) = (sz.width / 2.0, sz.height / 2.0);
    let turn = Affine::translate(-cx, -cy)
        .then(Affine::rotate(f64::from(quarter) * PI / 2.0))
        .then(Affine::translate(cx, cy));
    let origin = Point::new(cx - w / 2.0, cy - h / 2.0);
    let at = |x: f64, y: f64| Point::new(origin.x + x, origin.y + y);
    let white = Color::WHITE;
    let dim = Color::rgba(1.0, 1.0, 1.0, 0.8);
    let title = ui
        .deck
        .borrow()
        .as_ref()
        .map(|dk| dk.title.clone())
        .unwrap_or_default();

    d.transformed(turn, |d| match phase {
        Phase::Ready => {
            centered(
                d,
                &title,
                at(w / 2.0, h * 0.16),
                20.0,
                dim,
                FontWeight::Semibold,
            );
            let head = tr("ch_ready_title").format();
            let (lines, size) = fit_word(&head, w * 0.86, 44.0);
            for (i, line) in lines.iter().enumerate() {
                let y = h * 0.38 + i as f64 * size * 1.1;
                centered(d, line, at(w / 2.0, y), size, white, FontWeight::Black);
            }
            let hint = if ui.tilting.get_untracked() {
                tr("ch_ready_tilt").format()
            } else if ui.tilt_on.get_untracked() && ui.tilt_available {
                tr("ch_no_motion").format()
            } else {
                tr("ch_ready_buttons").format()
            };
            let (lines, size) = fit_word(&hint, w * 0.86, 20.0);
            for (i, line) in lines.iter().enumerate() {
                let y = h * 0.56 + i as f64 * size * 1.3;
                centered(d, line, at(w / 2.0, y), size, dim, FontWeight::Medium);
            }
        }
        Phase::Countdown => {
            let left = (COUNTDOWN - stage.in_phase).max(0.0);
            let n = left.ceil().max(1.0);
            // Each number lands big and settles as its second runs out.
            let frac = left - (n - 1.0);
            let size = h.min(w) * (0.42 + 0.12 * frac);
            centered(
                d,
                &tr("ch_get_ready").format(),
                at(w / 2.0, h * 0.18),
                24.0,
                dim,
                FontWeight::Bold,
            );
            centered(
                d,
                &format!("{n}"),
                at(w / 2.0, h * 0.55),
                size,
                white,
                FontWeight::Black,
            );
        }
        Phase::Play => {
            let round = ui.round.borrow();
            let Some(round) = round.as_ref() else { return };
            if let Some(mark) = flash {
                let banner = match mark {
                    Mark::Correct => tr("ch_correct_banner").format(),
                    Mark::Pass => tr("ch_pass_banner").format(),
                };
                let (_, size) = fit_word(&banner, w * 0.8, h * 0.3);
                centered(
                    d,
                    &banner,
                    at(w / 2.0, h * 0.45),
                    size,
                    white,
                    FontWeight::Black,
                );
                let (lines, size) = fit_word(&stage.flashed_word, w * 0.8, h * 0.1);
                for (i, line) in lines.iter().enumerate() {
                    let y = h * 0.64 + i as f64 * size * 1.1;
                    centered(d, line, at(w / 2.0, y), size, dim, FontWeight::Bold);
                }
                return;
            }
            let left = round.remaining();
            let urgent = left <= f64::from(model::WARN_FROM);
            let clock_color = if urgent {
                Color::rgb(1.0, 0.85, 0.3)
            } else {
                dim
            };
            let pulse = if urgent {
                1.0 + 0.12 * (1.0 - (left.fract()).abs())
            } else {
                1.0
            };
            centered(
                d,
                &fmt_clock(left),
                at(w / 2.0, h * 0.12),
                26.0 * pulse,
                clock_color,
                FontWeight::Bold,
            );
            let word = round.current().unwrap_or_default();
            let (lines, size) = fit_word(word, w * 0.9, h * 0.34);
            let total = size * 1.08 * lines.len() as f64;
            for (i, line) in lines.iter().enumerate() {
                let y = h * 0.5 - total / 2.0 + size * 1.08 * (i as f64 + 0.5);
                centered(d, line, at(w / 2.0, y), size, white, FontWeight::Black);
            }
            if ui.tilting.get_untracked() {
                centered(
                    d,
                    &tr("ch_tilt_hint").format(),
                    at(w / 2.0, h * 0.9),
                    15.0,
                    dim,
                    FontWeight::Medium,
                );
            }
        }
        Phase::TimeUp => {
            let out_of_cards = ui
                .round
                .borrow()
                .as_ref()
                .is_some_and(|r| r.remaining() > 0.0);
            let text = if out_of_cards {
                tr("ch_out_of_cards").format()
            } else {
                tr("ch_time_up").format()
            };
            let (_, size) = fit_word(&text, w * 0.85, h * 0.3);
            centered(
                d,
                &text,
                at(w / 2.0, h * 0.5),
                size,
                white,
                FontWeight::Black,
            );
        }
        Phase::Decks | Phase::Results => {}
    });
}

// ---------------------------------------------------------------------------
// The results
// ---------------------------------------------------------------------------

fn results_screen(ui: Rc<Ui>) -> AnyPiece {
    let (score, results) = ui
        .round
        .borrow()
        .as_ref()
        .map(|r| (r.score(), r.results.clone()))
        .unwrap_or_default();
    let (title, id) = ui
        .deck
        .borrow()
        .as_ref()
        .map(|d| (d.title.clone(), d.id))
        .unwrap_or_default();
    let mut rows = Vec::with_capacity(results.len());
    for (word, mark) in results {
        let (color, glyph) = match mark {
            Mark::Correct => (Color::WHITE, GREEN),
            Mark::Pass => (chrome::TEXT_DIM, chrome::TEXT_DIM),
        };
        rows.push(
            row((
                label(word).color(color).grow_w(),
                canvas(move |d, sz| {
                    let c = Point::new(sz.width / 2.0, sz.height / 2.0);
                    match mark {
                        Mark::Correct => chrome::draw_check_glyph(d, c, 16.0, glyph),
                        Mark::Pass => chrome::draw_cross_glyph(d, c, 14.0, glyph),
                    }
                })
                .frame(22.0, 22.0),
            ))
            .align(VAlign::Center)
            .width(300.0)
            .any(),
        );
    }
    let empty = rows.is_empty();
    let (au, du) = (ui.clone(), ui.clone());
    let best = when(
        {
            let u = ui.clone();
            move || u.new_best.get()
        },
        || {
            label(tr("ch_new_best"))
                .font(Font::Headline)
                .color(chrome::GOLD)
        },
    );
    let list = if empty {
        spacer().height(0.0).any()
    } else {
        scroll(column(PieceVec(rows)).spacing(8.0))
            .height(240.0)
            .any()
    };
    let card = chrome::card(
        column((
            label(title).font(Font::Headline).color(chrome::TEXT_DIM),
            chrome::stat(
                tr("ch_correct"),
                score.to_string(),
                Font::LargeTitle,
                chrome::GOLD,
                "ch-score",
            ),
            best,
            list,
            chrome::menu_button(tr("ch_play_again"), GREEN, "ch-again", move || au.start(id)),
            chrome::menu_button(tr("ch_decks"), chrome::BLUE, "ch-to-decks", move || {
                du.to_decks()
            }),
        ))
        .spacing(14.0)
        .align(HAlign::Center),
    )
    .id("ch-results");
    zstack((card,))
        .align(Alignment::Center)
        .grow()
        .background(SURFACE)
        .any()
}

// ---------------------------------------------------------------------------
// Cards over the game
// ---------------------------------------------------------------------------

fn overlays(ui: Rc<Ui>) -> impl Piece {
    let scrim = {
        let u = ui.clone();
        when(move || u.overlay.get() != Overlay::None, chrome::scrim)
    };
    let (p, s, i) = (ui.clone(), ui.clone(), ui.clone());
    let card = move |kind: Overlay, build: Rc<dyn Fn() -> AnyPiece>| {
        let u = ui.clone();
        when(move || u.overlay.get() == kind, move || build())
    };
    zstack((
        scrim,
        card(Overlay::Pause, Rc::new(move || pause_menu(p.clone()))),
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
            chrome::menu_button(tr("gk_resume"), chrome::GREEN, "ch-resume", move || {
                u1.show(Overlay::None)
            }),
            chrome::menu_button(
                tr("ch_end_round"),
                chrome::AMBER,
                "ch-end-round",
                move || {
                    // Ending early still counts what was played; a round that never started does not.
                    if u2.phase.get_untracked() == Phase::Play {
                        u2.finish();
                    } else {
                        u2.to_decks();
                    }
                },
            ),
            chrome::menu_button(
                tr("gk_settings"),
                chrome::SLATE,
                "ch-pause-settings",
                move || u3.push(Overlay::Settings),
            ),
            chrome::menu_button(
                tr("gk_instructions"),
                chrome::INDIGO,
                "ch-pause-instructions",
                move || u4.push(Overlay::Instructions),
            ),
            chrome::menu_button(tr("gk_quit"), chrome::RED, "ch-quit", || {
                nav_back();
            }),
        ))
        .spacing(14.0)
        .align(HAlign::Center),
    )
    .id("ch-pause-menu")
    .any()
}

fn settings_card(ui: Rc<Ui>) -> AnyPiece {
    let lengths: Vec<String> = LENGTHS
        .iter()
        .map(|s| tr("ch_seconds").arg("n", f64::from(*s)).format())
        .collect();
    let played: u32 = ui.records.borrow().played.values().sum();
    let tilt_detail = if ui.tilt_available {
        tr("ch_tilt_detail")
    } else {
        tr("ch_tilt_missing")
    };
    let reset = {
        let u = ui.clone();
        button(tr("ch_reset_records"))
            .tint(chrome::RED)
            .action(move || {
                let u = u.clone();
                day_core::task(async move {
                    let sure = Alert::new(tr("ch_reset_records_title"))
                        .message(tr("ch_reset_records_message"))
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
            .id("ch-reset-records")
    };
    let done = ui.clone();
    chrome::card(
        column((
            label(tr("gk_settings"))
                .font(Font::Title2)
                .bold()
                .color(Color::WHITE),
            chrome::section_heading(tr("nav_charades")),
            chrome::setting_row(tr("gk_sounds"), toggle(ui.sounds).id("ch-sounds").any()),
            chrome::setting_row(
                tr("gk_vibrations"),
                toggle(ui.vibrations).id("ch-vibrations").any(),
            ),
            chrome::setting_row(
                tr("ch_round_length"),
                picker(lengths, ui.length)
                    .menu()
                    .id("ch-round-length")
                    .any(),
            ),
            chrome::setting_row(
                tr("ch_tilt"),
                toggle(ui.tilt_on)
                    .enabled(ui.tilt_available)
                    .id("ch-tilt")
                    .any(),
            ),
            label(tilt_detail)
                .font(Font::Caption)
                .color(chrome::TEXT_DIM)
                .width(300.0),
            chrome::section_heading(tr("ch_records")),
            chrome::setting_row(
                tr("ch_rounds_played"),
                label(played.to_string())
                    .tabular()
                    .color(chrome::TEXT_DIM)
                    .id("ch-rounds-played")
                    .any(),
            ),
            reset,
            button(tr("gk_done"))
                .prominent()
                .action(move || done.pop())
                .id("ch-done"),
        ))
        .spacing(12.0)
        .align(HAlign::Center),
    )
    .id("ch-settings-card")
    .any()
}

fn instructions_card(ui: Rc<Ui>) -> AnyPiece {
    chrome::instructions_card(
        tr("nav_charades"),
        vec![
            Help::Para(tr("ch_help_intro")),
            Help::Heading(tr("ch_help_play")),
            Help::Para(tr("ch_help_play_1")),
            Help::Para(tr("ch_help_play_2")),
            Help::Para(tr("ch_help_play_3")),
            Help::Para(tr("ch_help_play_4")),
            Help::Heading(tr("ch_help_buttons")),
            Help::Para(tr("ch_help_buttons_1")),
        ],
        "ch-help-done",
        move || ui.pop(),
    )
    .id("ch-instructions-card")
    .any()
}

// ---------------------------------------------------------------------------
// The home tile
// ---------------------------------------------------------------------------

/// The home-screen tile: a phone held up sideways with a word on it, and the two ways to answer.
pub fn charades_preview() -> AnyPiece {
    canvas(|d, sz| {
        let (w, h) = (sz.width, sz.height);
        d.fill(
            Shape::Rect(Rect::new(0.0, 0.0, w, h)),
            LinearGradient::new(
                UnitPoint::TOP,
                UnitPoint::BOTTOM,
                vec![(0.0, Color::rgb(0.32, 0.18, 0.55)), (1.0, SURFACE)],
            ),
        );
        let c = Point::new(w / 2.0, h * 0.48);
        let (pw, ph) = (w * 0.72, w * 0.40);
        let tilt = Affine::translate(-c.x, -c.y)
            .then(Affine::rotate(-0.10))
            .then(Affine::translate(c.x, c.y));
        d.transformed(tilt, |d| {
            let (x, y) = (c.x - pw / 2.0, c.y - ph / 2.0);
            let body = Rect::new(x, y, pw, ph);
            d.fill(
                Shape::RoundedRect(body, ph * 0.16),
                Color::rgb(0.08, 0.08, 0.12),
            );
            let inset = ph * 0.07;
            let screen = Rect::new(x + inset, y + inset, pw - 2.0 * inset, ph - 2.0 * inset);
            d.fill(
                Shape::RoundedRect(screen, ph * 0.10),
                LinearGradient::new(
                    UnitPoint::TOP,
                    UnitPoint::BOTTOM,
                    vec![(0.0, PALETTE[0]), (1.0, blend(PALETTE[0], SURFACE, 0.4))],
                ),
            );
            centered(
                d,
                "Giraffe",
                Point::new(c.x, c.y),
                ph * 0.30,
                Color::WHITE,
                FontWeight::Black,
            );
        });
        // The two answers: a nod for correct, a tip back to pass.
        let r = w * 0.075;
        let row_y = h * 0.84;
        for (x, color, correct) in [(w * 0.3, GREEN, true), (w * 0.7, ORANGE, false)] {
            let p = Point::new(x, row_y);
            d.fill(
                Shape::Ellipse(Rect::new(p.x - r, p.y - r, 2.0 * r, 2.0 * r)),
                color,
            );
            if correct {
                chrome::draw_check_glyph(d, p, r * 1.1, Color::WHITE);
            } else {
                chrome::draw_cross_glyph(d, p, r * 0.95, Color::WHITE);
            }
        }
    })
    .any()
}
