//! Breakout — a real-time brick-breaker drawn on an immediate-mode canvas and driven by Day's
//! frame clock (§8.4), following Faire-Games' Breakout feature for feature: an eased,
//! finger-tracking paddle that can smash the ball up or down, multi-hit armored bricks, five
//! power-ups with timer badges, combos with score popups, particle bursts, a ball trail and a
//! side-wall predictor, level-clear and game-over cards, a pause menu, settings, and a
//! how-to-play sheet. A composite Day piece: pure composition over `day_pieces` plus the
//! shared `gamekit` chrome, so it renders the same on every backend.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use day_fluent::tr;
use day_part_haptics::Haptic;
use day_pieces::prelude::*;
use day_spec::Cursor;
use gamekit::chrome::cues::{self, with};
use gamekit::chrome::{self, Cue, Feedback, Help, Sfx, sfx};
use serde::{Deserialize, Serialize};

/// The prefs keys this game persists under (gamekit; bump the game key on schema change).
const SAVE_KEY: &str = "breakout.v2";
const RECORD_KEY: &str = "breakout.best";
const SETTINGS_KEY: &str = "breakout.settings";

// --- tuning (Faire's constants) ---------------------------------------------------------
/// The HUD strip above the play field.
const HUD_H: f64 = 44.0;
/// Leading gutter for the HUD, clear of the cover's close button.
const CLOSE_GUTTER: f64 = 52.0;
const PADDLE_H: f64 = 14.0;
/// The paddle rests this fraction of the field height above the bottom.
const PADDLE_BOTTOM_FRACTION: f64 = 0.25;
const BALL_R: f64 = 7.0;
const ROWS: usize = 8;
const COLS: usize = 10;
const BRICK_H: f64 = 16.0;
const BRICK_GAP: f64 = 2.0;
const BRICK_TOP: f64 = 80.0;
const BASE_SPEED: f64 = 320.0;
const PADDLE_W: f64 = 72.0;
const PADDLE_WIDE_W: f64 = 112.0;
const PADDLE_WIDTH_LERP: f64 = 6.0;
/// The paddle rides this far above the fingertip, so the finger never hides it.
const TOUCH_LIFT: f64 = 72.0;
/// Exponential easing rate toward the touch target (1/s): ~95% of the way in ~0.14 s,
/// independent of the frame rate.
const FOLLOW_RATE: f64 = 22.0;
/// The arrow keys move the paddle target this far per press (desktop).
const KEY_STEP: f64 = 40.0;

const PU_DROP_CHANCE: f64 = 0.20;
const PU_FALL: f64 = 130.0;
const PU_W: f64 = 30.0;
const PU_H: f64 = 16.0;
const CATCH_SCORE: i64 = 50;
const WIDE_DUR: f64 = 14.0;
const SLOW_DUR: f64 = 13.0;
const SLOW_FACTOR: f64 = 0.62;
const SMASH_DUR: f64 = 8.0;
const MAX_LIVES: i32 = 5;
/// Extra balls in flight at once (multi-ball splits the primary into three each catch).
const MAX_EXTRA_BALLS: usize = 8;

const COMBO_CAP: i64 = 4;
const COMBO_MIN_DISPLAY: i64 = 2;
const COMBO_DECAY: f64 = 1.4;

const PARTICLE_GRAVITY: f64 = 240.0;
const POPUP_LIFE: f64 = 0.85;
const POPUP_RISE: f64 = 60.0;
const TRAIL_MAX: usize = 7;

/// Classic rainbow, top row first.
const ROW_COLORS: [Color; 8] = [
    Color::rgb(0.90, 0.20, 0.20),
    Color::rgb(0.95, 0.40, 0.15),
    Color::rgb(0.95, 0.60, 0.10),
    Color::rgb(0.95, 0.80, 0.15),
    Color::rgb(0.40, 0.80, 0.25),
    Color::rgb(0.20, 0.70, 0.55),
    Color::rgb(0.30, 0.50, 0.90),
    Color::rgb(0.55, 0.35, 0.85),
];
/// Points per row (top rows are worth more).
const ROW_POINTS: [i64; 8] = [7, 7, 5, 5, 3, 3, 1, 1];

const BG_TOP: Color = Color::rgb(0.06, 0.06, 0.16);
const BG_BOTTOM: Color = Color::rgb(0.02, 0.02, 0.08);
const HUD_BG: Color = Color::rgb(0.04, 0.04, 0.12);
/// The game's cover surface color (edge-to-edge behind the safe area).
pub const SURFACE: Color = HUD_BG;

/// A tiny xorshift RNG — no `rand` dependency, deterministic per seed.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
    fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }
    fn range(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * self.unit()
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
enum Power {
    Wide,
    Multi,
    Slow,
    ExtraLife,
    Smash,
}

const POWERS: [Power; 5] = [
    Power::Wide,
    Power::Multi,
    Power::Slow,
    Power::ExtraLife,
    Power::Smash,
];

impl Power {
    fn letter(self) -> &'static str {
        match self {
            Power::Wide => "W",
            Power::Multi => "M",
            Power::Slow => "S",
            Power::ExtraLife => "+1",
            Power::Smash => "★",
        }
    }
    fn color(self) -> Color {
        match self {
            Power::Wide => Color::rgb(0.30, 0.72, 0.95),
            Power::Multi => Color::rgb(0.95, 0.40, 0.85),
            Power::Slow => Color::rgb(0.55, 0.55, 1.00),
            Power::ExtraLife => Color::rgb(0.42, 0.88, 0.45),
            Power::Smash => Color::rgb(1.00, 0.55, 0.20),
        }
    }
    /// Effect duration; zero means instantaneous (no timer badge).
    fn duration(self) -> f64 {
        match self {
            Power::Wide => WIDE_DUR,
            Power::Slow => SLOW_DUR,
            Power::Smash => SMASH_DUR,
            Power::Multi | Power::ExtraLife => 0.0,
        }
    }
}

#[derive(Clone, Copy, Default)]
struct Ball {
    x: f64,
    y: f64,
    dx: f64,
    dy: f64,
}

struct Drop {
    x: f64,
    y: f64,
    kind: Power,
}

struct Particle {
    x: f64,
    y: f64,
    dx: f64,
    dy: f64,
    life: f64,
    max: f64,
    color: Color,
    size: f64,
}

struct Popup {
    x: f64,
    y: f64,
    life: f64,
    text: String,
    color: Color,
}

#[derive(Clone, Copy)]
struct Brick {
    hp: u8,
    max_hp: u8,
    power: Option<Power>,
}

impl Brick {
    fn alive(&self) -> bool {
        self.hp > 0
    }
}

/// What a tick did that the page reacts to (haptics, cards).
#[derive(Clone, Copy, PartialEq, Debug)]
enum Happening {
    Launched,
    /// A brick broke at this combo count (1 = no combo).
    BrickBroken(i64),
    /// 0 = a mirror bounce off the paddle, 1 = the sharpest deflection.
    PaddleHit(f64),
    Caught(Power),
    LifeLost,
    LevelComplete,
    GameOver,
}

/// The durable snapshot (gamekit save/restore): the board, the primary ball, and progress.
/// Extras, power-ups, particles, and timers are session-only.
#[derive(Serialize, Deserialize)]
struct SaveState {
    paddle_x: f64,
    ball: (f64, f64, f64, f64),
    alive: Vec<bool>,
    score: i64,
    lives: i32,
    level: i32,
    game_over: bool,
    level_complete: bool,
    launched: bool,
}

struct Game {
    /// The play field below the HUD strip.
    field: Size,
    paddle_x: f64,
    paddle_y: f64,
    paddle_w: f64,
    /// The paddle before this tick's easing, for the swept paddle/ball test and the speed
    /// boost a fast paddle gives the ball.
    prev_px: f64,
    prev_py: f64,
    /// Where the touch wants the paddle; `step_paddle` eases toward it every tick.
    target_x: f64,
    target_y: f64,

    ball: Ball,
    extras: Vec<Ball>,
    trail: Vec<(f64, f64)>,
    /// `(right wall?, y)` where the primary ball is headed next, for the guide marker.
    predicted: Option<(bool, f64)>,

    bricks: Vec<Brick>,
    drops: Vec<Drop>,
    wide_t: f64,
    slow_t: f64,
    smash_t: f64,

    combo: i64,
    combo_decay: f64,

    particles: Vec<Particle>,
    popups: Vec<Popup>,

    score: i64,
    best: i64,
    lives: i32,
    level: i32,
    game_over: bool,
    level_complete: bool,
    launched: bool,

    brick_w: f64,
    brick_left: f64,
    ball_speed: f64,
    rng: Rng,
    happenings: Vec<Happening>,
    /// Bumped whenever the wall's look changes (a hit, a new level, a resize), so the wall
    /// layer re-records only then.
    wall_version: u32,
}

impl Game {
    fn new() -> Self {
        let mut g = Game {
            field: Size::new(400.0, 700.0),
            paddle_x: 200.0,
            paddle_y: 525.0,
            paddle_w: PADDLE_W,
            prev_px: 200.0,
            prev_py: 525.0,
            target_x: 200.0,
            target_y: 525.0,
            ball: Ball::default(),
            extras: Vec::new(),
            trail: Vec::new(),
            predicted: None,
            bricks: Vec::new(),
            drops: Vec::new(),
            wide_t: 0.0,
            slow_t: 0.0,
            smash_t: 0.0,
            combo: 0,
            combo_decay: 0.0,
            particles: Vec::new(),
            popups: Vec::new(),
            score: 0,
            best: 0,
            lives: 3,
            level: 1,
            game_over: false,
            level_complete: false,
            launched: false,
            brick_w: 36.0,
            brick_left: BRICK_GAP,
            ball_speed: BASE_SPEED,
            rng: Rng(gamekit::seed()),
            happenings: Vec::new(),
            wall_version: 0,
        };
        g.setup(400.0, 700.0);
        g.new_game();
        g
    }

    fn paddle_baseline(&self) -> f64 {
        self.field.height * (1.0 - PADDLE_BOTTOM_FRACTION) - PADDLE_H / 2.0
    }
    /// The paddle's highest reach: halfway down the field, so it never crowds the bricks.
    fn paddle_y_min(&self) -> f64 {
        self.field.height / 2.0
    }
    fn paddle_y_max(&self) -> f64 {
        self.field.height - PADDLE_H / 2.0 - 2.0
    }

    /// The field's size (below the HUD), on every layout change. A pre-launch ball stays
    /// glued to the paddle's new position.
    fn setup(&mut self, width: f64, height: f64) {
        if self.field.width == width && self.field.height == height {
            return;
        }
        self.field = Size::new(width, height);
        self.paddle_x = width / 2.0;
        self.paddle_y = self.paddle_baseline();
        self.prev_px = self.paddle_x;
        self.prev_py = self.paddle_y;
        self.target_x = self.paddle_x;
        self.target_y = self.paddle_y;
        if !self.launched {
            self.park_ball();
        }
        self.brick_w = (width - BRICK_GAP * (COLS as f64 + 1.0)) / COLS as f64;
        self.brick_left = BRICK_GAP;
        self.wall_version += 1;
    }

    fn new_game(&mut self) {
        self.score = 0;
        self.lives = 3;
        self.level = 1;
        self.game_over = false;
        self.level_complete = false;
        self.ball_speed = BASE_SPEED;
        self.clear_transient();
        self.build_level();
        self.reset_ball();
    }

    fn start_level(&mut self, level: i32) {
        self.level = level;
        self.level_complete = false;
        self.ball_speed = BASE_SPEED + (level - 1) as f64 * 25.0;
        self.clear_transient();
        self.build_level();
        self.reset_ball();
    }

    /// In-flight state that never survives a new game or level.
    fn clear_transient(&mut self) {
        self.extras.clear();
        self.trail.clear();
        self.drops.clear();
        self.particles.clear();
        self.popups.clear();
        self.wide_t = 0.0;
        self.slow_t = 0.0;
        self.smash_t = 0.0;
        self.combo = 0;
        self.combo_decay = 0.0;
        self.paddle_w = PADDLE_W;
        self.predicted = None;
    }

    /// Higher levels sprinkle tougher bricks along the top.
    fn brick_hp(row: usize, level: i32) -> u8 {
        if level >= 4 && row == 0 {
            3
        } else if (level >= 3 && row < 2) || (level >= 2 && row == 0) {
            2
        } else {
            1
        }
    }

    /// A fresh wall: every brick at its level's strength, two to four of them carrying a
    /// power-up.
    fn build_level(&mut self) {
        let total = ROWS * COLS;
        let n = 2 + self.rng.below(3);
        let mut cells: Vec<usize> = Vec::new();
        while cells.len() < n {
            let c = self.rng.below(total);
            if !cells.contains(&c) {
                cells.push(c);
            }
        }
        let level = self.level;
        self.bricks = (0..total)
            .map(|i| {
                let hp = Self::brick_hp(i / COLS, level);
                let power = if cells.contains(&i) {
                    Some(POWERS[self.rng.below(POWERS.len())])
                } else {
                    None
                };
                Brick {
                    hp,
                    max_hp: hp,
                    power,
                }
            })
            .collect();
        self.wall_version += 1;
    }

    fn park_ball(&mut self) {
        self.ball = Ball {
            x: self.paddle_x,
            y: self.paddle_y - PADDLE_H / 2.0 - BALL_R - 2.0,
            dx: 0.0,
            dy: 0.0,
        };
        self.trail.clear();
    }

    /// Sit the ball back on the paddle at its baseline, ready to launch.
    fn reset_ball(&mut self) {
        self.launched = false;
        self.paddle_y = self.paddle_baseline();
        self.prev_px = self.paddle_x;
        self.prev_py = self.paddle_y;
        self.target_x = self.paddle_x;
        self.target_y = self.paddle_y;
        self.park_ball();
        self.combo = 0;
        self.combo_decay = 0.0;
    }

    fn launch(&mut self) {
        if self.launched || self.game_over || self.level_complete {
            return;
        }
        self.launched = true;
        let angle = self.rng.range(-0.4, 0.4);
        self.ball.dx = self.ball_speed * angle.sin();
        self.ball.dy = -self.ball_speed * angle.cos();
        self.happenings.push(Happening::Launched);
    }

    /// The touch point, in field coordinates: the paddle centers on it horizontally and rides
    /// `TOUCH_LIFT` above it, within the walls and the vertical travel band.
    fn set_target(&mut self, x: f64, y: f64) {
        self.set_target_lifted(x, y, TOUCH_LIFT);
    }

    /// A pointer's position, in field coordinates: no lift, since a cursor hides nothing. The
    /// paddle follows it only inside its travel band, so a pointer over the wall or the HUD
    /// leaves the paddle where it is. Returns whether the pointer is in the band.
    fn set_pointer_target(&mut self, x: f64, y: f64) -> bool {
        let in_band = y >= self.paddle_y_min() && y <= self.field.height;
        if in_band {
            self.set_target_lifted(x, y, 0.0);
        }
        in_band
    }

    fn set_target_lifted(&mut self, x: f64, y: f64, lift: f64) {
        let half = self.paddle_w / 2.0;
        self.target_x = x.clamp(half, (self.field.width - half).max(half));
        self.target_y = (y - lift).clamp(self.paddle_y_min(), self.paddle_y_max());
    }

    fn nudge_target(&mut self, dx: f64) {
        let half = self.paddle_w / 2.0;
        self.target_x = (self.target_x + dx).clamp(half, (self.field.width - half).max(half));
    }

    /// Ease the paddle toward its target, frame-rate independently, before the physics step.
    fn step_paddle(&mut self, dt: f64) {
        self.prev_px = self.paddle_x;
        self.prev_py = self.paddle_y;
        let k = 1.0 - (-FOLLOW_RATE * dt).exp();
        self.paddle_x += (self.target_x - self.paddle_x) * k;
        self.paddle_y += (self.target_y - self.paddle_y) * k;
        // A ball waiting to launch rides on the paddle wherever it goes.
        if !self.launched {
            self.park_ball();
        }
    }

    fn live(&self) -> bool {
        self.launched && !self.game_over && !self.level_complete
    }

    fn current_speed(&self) -> f64 {
        let cleared = self.bricks.iter().filter(|b| !b.alive()).count();
        self.ball_speed + cleared as f64 * 1.5
    }

    fn update(&mut self, dt: f64) {
        if !self.live() {
            return;
        }
        for t in [&mut self.wide_t, &mut self.slow_t, &mut self.smash_t] {
            *t = (*t - dt).max(0.0);
        }
        let target_w = if self.wide_t > 0.0 {
            PADDLE_WIDE_W
        } else {
            PADDLE_W
        };
        self.paddle_w += (target_w - self.paddle_w) * (dt * PADDLE_WIDTH_LERP).min(1.0);
        let scale = if self.slow_t > 0.0 { SLOW_FACTOR } else { 1.0 };

        // Balls. The primary is stepped by value so the collision code can borrow `self`.
        let mut primary = self.ball;
        let primary_lost = self.step_ball(&mut primary, dt, scale, true);
        self.ball = primary;
        let mut i = 0;
        while i < self.extras.len() {
            let mut b = self.extras[i];
            if self.step_ball(&mut b, dt, scale, false) {
                self.extras.swap_remove(i);
            } else {
                self.extras[i] = b;
                i += 1;
            }
        }

        self.trail.push((self.ball.x, self.ball.y));
        while self.trail.len() > TRAIL_MAX {
            self.trail.remove(0);
        }
        self.update_prediction();

        if self.combo > 0 {
            self.combo_decay -= dt;
            if self.combo_decay <= 0.0 {
                self.combo = 0;
            }
        }

        // Falling power-ups: descend, catch on the paddle, or leave off the bottom.
        let paddle_top = self.paddle_y - PADDLE_H / 2.0;
        let (pl, pr) = (
            self.paddle_x - self.paddle_w / 2.0,
            self.paddle_x + self.paddle_w / 2.0,
        );
        let mut i = 0;
        while i < self.drops.len() {
            self.drops[i].y += PU_FALL * dt;
            let d = &self.drops[i];
            if d.y > self.field.height + PU_H {
                self.drops.swap_remove(i);
                continue;
            }
            let caught = d.y + PU_H / 2.0 >= paddle_top
                && d.y - PU_H / 2.0 <= paddle_top + PADDLE_H
                && d.x + PU_W / 2.0 >= pl
                && d.x - PU_W / 2.0 <= pr;
            if caught {
                let (kind, x, y) = (d.kind, d.x, d.y);
                self.drops.swap_remove(i);
                self.apply_power(kind, x, y);
                continue;
            }
            i += 1;
        }

        // Particles and popups.
        let floor = self.field.height + 30.0;
        self.particles.retain_mut(|p| {
            p.dy += PARTICLE_GRAVITY * dt;
            p.x += p.dx * dt;
            p.y += p.dy * dt;
            p.life -= dt;
            p.life > 0.0 && p.y <= floor
        });
        self.popups.retain_mut(|s| {
            s.y -= POPUP_RISE * dt;
            s.life -= dt;
            s.life > 0.0
        });

        if primary_lost {
            if self.extras.is_empty() {
                self.lives -= 1;
                self.combo = 0;
                self.wide_t = 0.0;
                self.slow_t = 0.0;
                self.smash_t = 0.0;
                self.paddle_w = PADDLE_W;
                self.drops.clear();
                if self.lives <= 0 {
                    self.game_over = true;
                    self.record_best();
                    self.happenings.push(Happening::GameOver);
                } else {
                    self.reset_ball();
                    self.happenings.push(Happening::LifeLost);
                }
                return;
            }
            // Promote the most central extra so the demotion feels natural.
            let cx = self.field.width / 2.0;
            let mut best = 0;
            for k in 1..self.extras.len() {
                if (self.extras[k].x - cx).abs() < (self.extras[best].x - cx).abs() {
                    best = k;
                }
            }
            self.ball = self.extras.remove(best);
            self.trail.clear();
        }

        if self.bricks.iter().all(|b| !b.alive()) {
            self.level_complete = true;
            self.record_best();
            self.clear_transient();
            self.happenings.push(Happening::LevelComplete);
        }
    }

    /// Integrate one ball (sub-stepped so a fast ball never skips a brick), bouncing it off
    /// the walls, the swept paddle, and the bricks. Returns whether it fell below the field.
    fn step_ball(&mut self, b: &mut Ball, dt: f64, scale: f64, primary: bool) -> bool {
        let (w, h) = (self.field.width, self.field.height);
        let eff = dt * scale;
        let dist = (b.dx * b.dx + b.dy * b.dy).sqrt() * eff;
        let steps = (dist / (BALL_R * 0.9)).ceil().clamp(1.0, 8.0) as usize;
        let sub = eff / steps as f64;
        // The paddle's sweep this tick, shared by every sub-step.
        let paddle_top = self.paddle_y - PADDLE_H / 2.0;
        let prev_top = self.prev_py - PADDLE_H / 2.0;
        let paddle_bottom = self.paddle_y + PADDLE_H / 2.0;
        let prev_bottom = self.prev_py + PADDLE_H / 2.0;
        let swept_l = self.prev_px.min(self.paddle_x) - self.paddle_w / 2.0;
        let swept_r = self.prev_px.max(self.paddle_x) + self.paddle_w / 2.0;
        let paddle_vy = if dt > 0.0 {
            (self.paddle_y - self.prev_py) / dt
        } else {
            0.0
        };
        for _ in 0..steps {
            let py = b.y;
            b.x += b.dx * sub;
            b.y += b.dy * sub;

            if b.x - BALL_R < 0.0 {
                b.x = BALL_R;
                b.dx = b.dx.abs();
            } else if b.x + BALL_R > w {
                b.x = w - BALL_R;
                b.dx = -b.dx.abs();
            }
            if b.y - BALL_R < 0.0 {
                b.y = BALL_R;
                b.dy = b.dy.abs();
            }

            // Paddle: swept against its motion this tick, so neither a fast ball nor a
            // fast paddle tunnels through the other.
            let in_span = b.x >= swept_l - BALL_R && b.x <= swept_r + BALL_R;
            let crossed_down = py + BALL_R <= prev_top && b.y + BALL_R >= paddle_top;
            let overlap = b.dy > 0.0
                && b.y + BALL_R >= paddle_top
                && b.y + BALL_R <= paddle_top + PADDLE_H + 4.0;
            if b.dy > 0.0 && (crossed_down || overlap) {
                if in_span {
                    let incoming = b.dx.atan2(b.dy);
                    b.y = paddle_top - BALL_R;
                    let hit = ((b.x - self.paddle_x) / (self.paddle_w / 2.0)).clamp(-0.95, 0.95);
                    let out = hit * 1.15;
                    // A paddle moving up into the ball hands it some of its own speed.
                    let boost = ((-paddle_vy).max(0.0) * 0.45).min(self.current_speed() * 0.6);
                    let speed = self.current_speed() + boost;
                    b.dx = speed * out.sin();
                    b.dy = -speed * out.cos();
                    if primary {
                        let diff = (out - (-incoming)).abs();
                        self.happenings
                            .push(Happening::PaddleHit((diff / (2.0 * 1.15)).min(1.0)));
                        self.combo = 0;
                    }
                }
            } else {
                // Smash from above: the paddle's bottom edge crashed down through the ball,
                // which is punted further down instead of slipping through.
                let smashed = py - BALL_R >= prev_bottom && b.y - BALL_R <= paddle_bottom;
                if smashed && in_span {
                    b.y = paddle_bottom + BALL_R;
                    let hit = ((b.x - self.paddle_x) / (self.paddle_w / 2.0)).clamp(-0.95, 0.95);
                    let out = hit * 1.15;
                    let boost = (paddle_vy.max(0.0) * 0.6).min(self.current_speed() * 0.8);
                    let speed = self.current_speed() + boost;
                    b.dx = speed * out.sin();
                    b.dy = speed * out.cos();
                    if primary {
                        self.combo = 0;
                        self.happenings.push(Happening::PaddleHit(1.0));
                    }
                }
            }

            if b.y - BALL_R > h {
                return true;
            }
            self.hit_bricks(b, primary);
        }
        false
    }

    fn brick_rect(&self, i: usize) -> Rect {
        let (r, c) = (i / COLS, i % COLS);
        Rect::new(
            self.brick_left + c as f64 * (self.brick_w + BRICK_GAP),
            BRICK_TOP + r as f64 * (BRICK_H + BRICK_GAP),
            self.brick_w,
            BRICK_H,
        )
    }

    /// The first live brick the ball overlaps takes the hit and reflects it; a smash ball
    /// flattens every brick it touches and keeps going.
    fn hit_bricks(&mut self, b: &mut Ball, primary: bool) {
        let smash = self.smash_t > 0.0;
        for i in 0..self.bricks.len() {
            if !self.bricks[i].alive() {
                continue;
            }
            let rect = self.brick_rect(i);
            let cx = b.x.clamp(rect.origin.x, rect.origin.x + rect.size.width);
            let cy = b.y.clamp(rect.origin.y, rect.origin.y + rect.size.height);
            let (dx, dy) = (b.x - cx, b.y - cy);
            if dx * dx + dy * dy >= BALL_R * BALL_R {
                continue;
            }
            if smash {
                self.bricks[i].hp = 1;
                self.on_brick_hit(i, primary);
                continue;
            }
            self.on_brick_hit(i, primary);
            let overlap_l = (b.x + BALL_R) - rect.origin.x;
            let overlap_r = (rect.origin.x + rect.size.width) - (b.x - BALL_R);
            let overlap_t = (b.y + BALL_R) - rect.origin.y;
            let overlap_b = (rect.origin.y + rect.size.height) - (b.y - BALL_R);
            if overlap_l.min(overlap_r) < overlap_t.min(overlap_b) {
                b.dx = -b.dx;
                b.x = if overlap_l < overlap_r {
                    rect.origin.x - BALL_R
                } else {
                    rect.origin.x + rect.size.width + BALL_R
                };
            } else {
                b.dy = -b.dy;
                b.y = if overlap_t < overlap_b {
                    rect.origin.y - BALL_R
                } else {
                    rect.origin.y + rect.size.height + BALL_R
                };
            }
            return;
        }
    }

    /// Knock a brick down one hit point: a break scores its row (times the combo for the
    /// primary ball), bursts, pops a score, and drops its power-up; a dent scores one.
    fn on_brick_hit(&mut self, i: usize, primary: bool) {
        let rect = self.brick_rect(i);
        let (cx, cy) = (
            rect.origin.x + rect.size.width / 2.0,
            rect.origin.y + rect.size.height / 2.0,
        );
        let row = i / COLS;
        let color = ROW_COLORS[row % ROW_COLORS.len()];
        self.bricks[i].hp = self.bricks[i].hp.saturating_sub(1);
        self.wall_version += 1;
        if self.bricks[i].hp == 0 {
            let multiplier = if primary {
                self.combo += 1;
                self.combo_decay = COMBO_DECAY;
                self.combo.min(COMBO_CAP)
            } else {
                1
            };
            let earned = ROW_POINTS[row.min(ROW_POINTS.len() - 1)] * multiplier;
            self.score += earned;
            self.spawn_burst(cx, cy, color, 9, 80.0, 170.0, 0.45, 0.85, 2.2, 3.6, -40.0);
            let text = if multiplier > 1 {
                format!("+{earned} x{multiplier}")
            } else {
                format!("+{earned}")
            };
            self.popups.push(Popup {
                x: cx,
                y: cy,
                life: POPUP_LIFE,
                text,
                color,
            });
            let kind = match self.bricks[i].power.take() {
                Some(k) => Some(k),
                None if self.rng.unit() < PU_DROP_CHANCE * 0.25 => {
                    Some(POWERS[self.rng.below(POWERS.len())])
                }
                None => None,
            };
            if let Some(kind) = kind {
                self.drops.push(Drop { x: cx, y: cy, kind });
            }
            self.happenings.push(Happening::BrickBroken(multiplier));
        } else {
            self.score += 1;
            self.popups.push(Popup {
                x: cx,
                y: cy,
                life: POPUP_LIFE,
                text: "+1".to_string(),
                color: Color::WHITE,
            });
            self.spawn_burst(cx, cy, color, 3, 40.0, 90.0, 0.25, 0.45, 2.0, 2.0, -20.0);
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn spawn_burst(
        &mut self,
        x: f64,
        y: f64,
        color: Color,
        n: usize,
        speed_lo: f64,
        speed_hi: f64,
        life_lo: f64,
        life_hi: f64,
        size_lo: f64,
        size_hi: f64,
        lift: f64,
    ) {
        for k in 0..n {
            let angle = k as f64 * (std::f64::consts::TAU / n as f64) + self.rng.range(-0.2, 0.2);
            let speed = self.rng.range(speed_lo, speed_hi);
            let life = self.rng.range(life_lo, life_hi);
            self.particles.push(Particle {
                x,
                y,
                dx: angle.cos() * speed,
                dy: angle.sin() * speed + lift,
                life,
                max: life,
                color,
                size: self.rng.range(size_lo, size_hi),
            });
        }
    }

    fn apply_power(&mut self, kind: Power, x: f64, y: f64) {
        self.score += CATCH_SCORE;
        self.popups.push(Popup {
            x,
            y,
            life: POPUP_LIFE,
            text: format!("+{CATCH_SCORE}"),
            color: kind.color(),
        });
        match kind {
            Power::Wide => self.wide_t = WIDE_DUR,
            Power::Slow => self.slow_t = SLOW_DUR,
            Power::Multi => self.spawn_multi(),
            Power::ExtraLife => {
                self.lives = (self.lives + 1).min(MAX_LIVES);
                let (px, py) = (self.paddle_x, self.paddle_y);
                self.spawn_burst(
                    px,
                    py,
                    kind.color(),
                    14,
                    90.0,
                    190.0,
                    0.6,
                    1.0,
                    2.5,
                    4.0,
                    -100.0,
                );
            }
            Power::Smash => {
                self.smash_t = SMASH_DUR;
                let (bx, by) = (self.ball.x, self.ball.y);
                self.spawn_burst(
                    bx,
                    by,
                    kind.color(),
                    10,
                    60.0,
                    160.0,
                    0.35,
                    0.7,
                    2.5,
                    3.5,
                    -30.0,
                );
            }
        }
        self.happenings.push(Happening::Caught(kind));
    }

    /// Split the primary ball into three: the original plus two extras at ±0.32 rad.
    fn spawn_multi(&mut self) {
        let b = self.ball;
        let speed = (b.dx * b.dx + b.dy * b.dy).sqrt();
        let base = b.dx.atan2(-b.dy);
        for off in [0.32, -0.32] {
            if self.extras.len() >= MAX_EXTRA_BALLS {
                break;
            }
            let a = base + off;
            self.extras.push(Ball {
                x: b.x,
                y: b.y,
                dx: speed * a.sin(),
                dy: -speed * a.cos(),
            });
        }
    }

    /// Where the primary ball will next meet a side wall, ignoring bricks — the guide marker.
    fn update_prediction(&mut self) {
        let b = self.ball;
        self.predicted = None;
        if b.dx == 0.0 || !self.launched {
            return;
        }
        let right = b.dx > 0.0;
        let target_x = if right {
            self.field.width - BALL_R
        } else {
            BALL_R
        };
        let t = (target_x - b.x) / b.dx;
        if t <= 0.0 {
            return;
        }
        let y = b.y + b.dy * t;
        if y < BALL_R || y > self.paddle_y - PADDLE_H / 2.0 {
            return;
        }
        self.predicted = Some((right, y));
    }

    fn record_best(&mut self) {
        if self.score > self.best {
            self.best = self.score;
            gamekit::save(RECORD_KEY, &self.best);
        }
    }

    fn save_state(&self) -> SaveState {
        SaveState {
            paddle_x: self.paddle_x,
            ball: (self.ball.x, self.ball.y, self.ball.dx, self.ball.dy),
            alive: self.bricks.iter().map(|b| b.alive()).collect(),
            score: self.score,
            lives: self.lives,
            level: self.level,
            game_over: self.game_over,
            level_complete: self.level_complete,
            launched: self.launched,
        }
    }

    /// Rebuild from a snapshot: the wall's survivors at full strength, the primary ball where
    /// it was, transients dropped.
    fn apply_save(&mut self, s: SaveState) {
        if s.alive.len() != ROWS * COLS {
            return;
        }
        self.score = s.score;
        self.lives = s.lives.clamp(0, MAX_LIVES);
        self.level = s.level.max(1);
        self.game_over = s.game_over;
        self.level_complete = s.level_complete;
        self.launched = s.launched;
        self.ball_speed = BASE_SPEED + (self.level - 1) as f64 * 25.0;
        self.clear_transient();
        self.build_level();
        for (brick, alive) in self.bricks.iter_mut().zip(s.alive) {
            if !alive {
                brick.hp = 0;
            }
        }
        self.wall_version += 1;
        self.paddle_x = s.paddle_x;
        self.prev_px = self.paddle_x;
        self.prev_py = self.paddle_y;
        self.target_x = self.paddle_x;
        self.target_y = self.paddle_y;
        self.ball = Ball {
            x: s.ball.0,
            y: s.ball.1,
            dx: s.ball.2,
            dy: s.ball.3,
        };
        if !self.launched {
            self.park_ball();
        }
    }

    // --- drawing --------------------------------------------------------------------------

    /// Everything in one pass, for the home tile. The page draws the same scene as FOUR
    /// canvases stacked in a `zstack`, each re-recorded on its own schedule: the backdrop
    /// once, the wall when a brick changes, the HUD when a number changes, and the play
    /// layer (ball, paddle, particles, popups) every frame — so a frame costs the native
    /// rasterizer a few dozen ops rather than the whole wall.
    fn draw(&self, d: &mut Draw, sz: Size) {
        self.draw_backdrop(d, sz);
        self.draw_hud(d, sz.width);
        d.transformed(Affine::translate(0.0, HUD_H), |d| {
            self.draw_wall(d);
            self.draw_play(d);
        });
    }

    fn draw_backdrop(&self, d: &mut Draw, sz: Size) {
        let (w, h) = (sz.width, sz.height);
        d.fill(
            Shape::Rect(Rect::new(0.0, 0.0, w, h)),
            LinearGradient::new(
                UnitPoint::TOP,
                UnitPoint::BOTTOM,
                vec![(0.0, BG_TOP), (1.0, BG_BOTTOM)],
            ),
        );
        // A soft glow above the paddle gives the field depth.
        let glow = 280.0;
        let (gx, gy) = (w / 2.0, HUD_H + (h - HUD_H) * 0.55);
        d.fill(
            Shape::Ellipse(Rect::new(gx - glow, gy - glow, 2.0 * glow, 2.0 * glow)),
            RadialGradient::new(
                UnitPoint::CENTER,
                0.5,
                vec![
                    (0.0, Color::rgba(1.0, 1.0, 1.0, 0.04)),
                    (1.0, Color::rgba(1.0, 1.0, 1.0, 0.0)),
                ],
            ),
        );
    }

    /// The wall layer: bricks only, in field coordinates.
    fn draw_wall(&self, d: &mut Draw) {
        for (i, brick) in self.bricks.iter().enumerate() {
            if brick.alive() {
                self.draw_brick(d, i, brick);
            }
        }
    }

    fn draw_hud(&self, d: &mut Draw, w: f64) {
        d.fill(Shape::Rect(Rect::new(0.0, 0.0, w, HUD_H)), HUD_BG);
        let mono = |color: Color| TextStyle {
            size: 12.0,
            color,
            anchor: TextAnchor {
                h: TextAlign::Leading,
                v: TextVAlign::Middle,
            },
            font: CanvasFont {
                family: None,
                weight: Some(FontWeight::Bold),
                italic: false,
            },
        };
        // Lives as dots, centered; the score and level narrow to fit the room either side of them.
        let lives = self.lives.max(0) as f64;
        let dots = (lives * 14.0 - 4.0).max(0.0);
        let start = w / 2.0 - dots / 2.0;
        let plain = mono(Color::WHITE).font;
        let score = tr("bk_score").arg("n", self.score).format();
        d.text(
            &score,
            Point::new(CLOSE_GUTTER, HUD_H / 2.0),
            TextStyle {
                size: chrome::fit_text(&score, 12.0, &plain, start - 12.0 - CLOSE_GUTTER),
                ..mono(Color::WHITE)
            },
        );
        for i in 0..self.lives.max(0) {
            d.fill(
                Shape::Ellipse(Rect::new(
                    start + i as f64 * 14.0,
                    HUD_H / 2.0 - 5.0,
                    10.0,
                    10.0,
                )),
                Color::rgb(0.9, 0.3, 0.3),
            );
        }
        let level = tr("bk_level").arg("n", self.level as i64).format();
        d.text(
            &level,
            Point::new(w - CLOSE_GUTTER, HUD_H / 2.0),
            TextStyle {
                size: chrome::fit_text(
                    &level,
                    12.0,
                    &plain,
                    w / 2.0 - dots / 2.0 - 12.0 - CLOSE_GUTTER,
                ),
                anchor: TextAnchor {
                    h: TextAlign::Trailing,
                    v: TextVAlign::Middle,
                },
                ..mono(Color::rgba(1.0, 1.0, 1.0, 0.7))
            },
        );
    }

    /// The play layer: everything that moves, in field coordinates.
    fn draw_play(&self, d: &mut Draw) {
        let (w, h) = (self.field.width, self.field.height);

        // Side-wall guide: a glowing dash where the primary ball will next hit, brighter
        // as the ball closes in.
        if let Some((right, y)) = self.predicted {
            let dist = if right {
                (w - self.ball.x).max(0.0)
            } else {
                self.ball.x.max(0.0)
            };
            let fade = (w * 0.35).max(80.0);
            let intensity = 1.0 - (dist / fade).min(1.0) * 0.65;
            let base = Color::rgb(0.55, 0.85, 1.0);
            let x = if right { w - 1.5 } else { 1.5 };
            d.fill(
                Shape::RoundedRect(Rect::new(x - 6.0, y - 20.0, 12.0, 40.0), 3.0),
                base.with_alpha(0.18 * intensity),
            );
            d.fill(
                Shape::RoundedRect(Rect::new(x - 1.5, y - 13.0, 3.0, 26.0), 1.5),
                base.with_alpha(0.85 * intensity),
            );
        }

        // Falling power-ups.
        for dr in &self.drops {
            let c = dr.kind.color();
            let body = Rect::new(dr.x - PU_W / 2.0, dr.y - PU_H / 2.0, PU_W, PU_H);
            d.fill(
                Shape::RoundedRect(
                    Rect::new(
                        dr.x - PU_W / 2.0 - 6.0,
                        dr.y - PU_H / 2.0 - 5.0,
                        PU_W + 12.0,
                        PU_H + 10.0,
                    ),
                    PU_H / 2.0 + 5.0,
                ),
                c.with_alpha(0.28),
            );
            d.fill(
                Shape::RoundedRect(body, PU_H / 2.0),
                LinearGradient::new(
                    UnitPoint::TOP,
                    UnitPoint::BOTTOM,
                    vec![(0.0, c.with_alpha(0.95)), (1.0, c.with_alpha(0.65))],
                ),
            );
            d.stroke(
                Shape::RoundedRect(body, PU_H / 2.0),
                Color::rgba(1.0, 1.0, 1.0, 0.75),
                1.0,
            );
            d.text(
                dr.kind.letter(),
                Point::new(dr.x, dr.y),
                TextStyle {
                    size: 11.0,
                    color: Color::WHITE,
                    anchor: TextAnchor::CENTERED,
                    font: chrome::canvas_font(FontWeight::Heavy),
                },
            );
        }

        // Particles.
        for p in &self.particles {
            let a = (p.life / p.max).clamp(0.0, 1.0);
            d.fill(
                Shape::Ellipse(Rect::new(
                    p.x - p.size / 2.0,
                    p.y - p.size / 2.0,
                    p.size,
                    p.size,
                )),
                p.color.with_alpha(a),
            );
        }

        // Score popups.
        for s in &self.popups {
            let a = (s.life / POPUP_LIFE).clamp(0.0, 1.0);
            let style = |color: Color| TextStyle {
                size: 13.0,
                color,
                anchor: TextAnchor::CENTERED,
                font: chrome::canvas_font(FontWeight::Heavy),
            };
            d.text(
                &s.text,
                Point::new(s.x, s.y + 1.0),
                style(Color::rgba(0.0, 0.0, 0.0, 0.5 * a)),
            );
            d.text(&s.text, Point::new(s.x, s.y), style(s.color.with_alpha(a)));
        }

        // Ball trail (primary), then the balls, then the paddle over everything so a
        // power-up slides under it as it is caught.
        for (i, (x, y)) in self.trail.iter().enumerate() {
            let frac = (i + 1) as f64 / (TRAIL_MAX + 1) as f64;
            let r = BALL_R * (0.35 + 0.55 * frac);
            d.fill(
                Shape::Ellipse(Rect::new(x - r, y - r, 2.0 * r, 2.0 * r)),
                Color::rgba(1.0, 1.0, 1.0, 0.10 + 0.20 * frac),
            );
        }
        self.draw_ball(d, self.ball.x, self.ball.y);
        for b in &self.extras {
            self.draw_ball(d, b.x, b.y);
        }
        self.draw_paddle(d);

        // Timer badges along the top of the field.
        let mut bx = 8.0;
        for (kind, remaining) in [
            (Power::Wide, self.wide_t),
            (Power::Slow, self.slow_t),
            (Power::Smash, self.smash_t),
        ] {
            if remaining > 0.0 {
                self.draw_badge(d, &mut bx, kind, remaining / kind.duration());
            }
        }

        // Combo flash near the top center.
        if self.combo >= COMBO_MIN_DISPLAY {
            let text = format!("x{}", self.combo.min(COMBO_CAP));
            let (cx, cy) = (w / 2.0, 46.0);
            d.fill(
                Shape::RoundedRect(Rect::new(cx - 34.0, cy - 19.0, 68.0, 38.0), 19.0),
                Color::rgba(0.0, 0.0, 0.0, 0.45),
            );
            d.text(
                &text,
                Point::new(cx, cy),
                TextStyle {
                    size: 26.0,
                    color: chrome::GOLD,
                    anchor: TextAnchor::CENTERED,
                    font: chrome::canvas_font(FontWeight::Black),
                },
            );
        }

        // Launch prompt.
        if !self.launched && !self.game_over && !self.level_complete {
            d.text(
                &tr("bk_tap_to_launch").format(),
                Point::new(w / 2.0, h / 2.0 - 10.0),
                TextStyle {
                    size: 17.0,
                    color: Color::WHITE,
                    anchor: TextAnchor::CENTERED,
                    font: chrome::canvas_font(FontWeight::Black),
                },
            );
            d.text(
                &tr("bk_drag_to_move").format(),
                Point::new(w / 2.0, h / 2.0 + 14.0),
                TextStyle {
                    size: 12.0,
                    color: Color::rgba(1.0, 1.0, 1.0, 0.6),
                    anchor: TextAnchor::CENTERED,
                    font: chrome::canvas_font(FontWeight::Bold),
                },
            );
        }
    }

    fn draw_brick(&self, d: &mut Draw, i: usize, brick: &Brick) {
        let rect = self.brick_rect(i);
        let row = i / COLS;
        let base = ROW_COLORS[row % ROW_COLORS.len()];
        // Armored bricks render darker until damaged, then brighten to their row color.
        let damage = if brick.max_hp > 1 {
            (brick.max_hp - brick.hp) as f64 / (brick.max_hp - 1).max(1) as f64
        } else {
            1.0
        };
        let armor = if brick.max_hp > 1 {
            (1.0 - damage) * 0.35
        } else {
            0.0
        };
        let (r, g, b) = (
            (base.r - armor).max(0.0),
            (base.g - armor).max(0.0),
            (base.b - armor).max(0.0),
        );
        let fill = Color::rgb(r, g, b);
        let light = Color::rgb(
            (r + 0.18).min(1.0),
            (g + 0.18).min(1.0),
            (b + 0.18).min(1.0),
        );
        let dark = Color::rgb(
            (r - 0.15).max(0.0),
            (g - 0.15).max(0.0),
            (b - 0.15).max(0.0),
        );
        let (x, y, bw, bh) = (
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height,
        );
        d.fill(Shape::RoundedRect(rect, 3.0), fill);
        d.fill(
            Shape::RoundedRect(Rect::new(x + 1.0, y + bh * 0.075, bw - 2.0, bh * 0.45), 3.0),
            light,
        );
        d.fill(
            Shape::RoundedRect(Rect::new(x + 1.0, y + bh * 0.75, bw - 2.0, bh * 0.2), 3.0),
            dark,
        );
        if brick.max_hp > 1 {
            d.stroke(
                Shape::RoundedRect(Rect::new(x + 0.5, y + 0.5, bw - 1.0, bh - 1.0), 3.0),
                Color::rgba(1.0, 1.0, 1.0, 0.55),
                1.0,
            );
        }
        if let Some(kind) = brick.power {
            // A tinted sheen and halo pull the eye; the white glyph says which pickup.
            let tint = kind.color();
            d.fill(
                Shape::RoundedRect(
                    Rect::new(x + bw * 0.025, y + bh * 0.17, bw * 0.95, bh * 0.30),
                    bh * 0.15,
                ),
                LinearGradient::new(
                    UnitPoint::LEADING,
                    UnitPoint::TRAILING,
                    vec![
                        (0.0, tint.with_alpha(0.0)),
                        (0.5, tint.with_alpha(0.75)),
                        (1.0, tint.with_alpha(0.0)),
                    ],
                ),
            );
            d.stroke(
                Shape::RoundedRect(Rect::new(x + 0.5, y + 0.5, bw - 1.0, bh - 1.0), 3.0),
                tint.with_alpha(0.85),
                1.0,
            );
            let (cx, cy) = (x + bw / 2.0, y + bh / 2.0);
            let glyph = Color::rgba(1.0, 1.0, 1.0, 0.95);
            let dot = |d: &mut Draw, px: f64, py: f64, r: f64| {
                d.fill(
                    Shape::Ellipse(Rect::new(px - r, py - r, 2.0 * r, 2.0 * r)),
                    glyph,
                );
            };
            let bar = |d: &mut Draw, px: f64, py: f64, len: f64, thick: f64| {
                d.fill(
                    Shape::RoundedRect(
                        Rect::new(px - len / 2.0, py - thick / 2.0, len, thick),
                        thick / 2.0,
                    ),
                    glyph,
                );
            };
            match kind {
                Power::Wide => {
                    dot(d, cx - 6.5, cy, 1.25);
                    bar(d, cx, cy, 8.0, 2.5);
                    dot(d, cx + 6.5, cy, 1.25);
                }
                Power::Multi => {
                    for k in -1..=1 {
                        dot(d, cx + k as f64 * 4.1, cy, 1.3);
                    }
                }
                Power::Slow => {
                    d.stroke(
                        Shape::Ellipse(Rect::new(cx - 3.0, cy - 3.0, 6.0, 6.0)),
                        glyph,
                        1.3,
                    );
                }
                Power::ExtraLife => {
                    bar(d, cx, cy, 7.0, 1.7);
                    d.fill(
                        Shape::RoundedRect(Rect::new(cx - 0.85, cy - 3.5, 1.7, 7.0), 0.85),
                        glyph,
                    );
                }
                Power::Smash => {
                    bar(d, cx, cy, 8.0, 1.6);
                    d.fill(
                        Shape::RoundedRect(Rect::new(cx - 0.8, cy - 4.0, 1.6, 8.0), 0.8),
                        glyph,
                    );
                    for a in [45.0f64, -45.0] {
                        d.transformed(
                            Affine::rotate(a.to_radians()).then(Affine::translate(cx, cy)),
                            |d| {
                                d.fill(
                                    Shape::RoundedRect(Rect::new(-3.0, -0.65, 6.0, 1.3), 0.65),
                                    glyph,
                                );
                            },
                        );
                    }
                }
            }
        }
    }

    fn draw_ball(&self, d: &mut Draw, x: f64, y: f64) {
        let (core, halo, mult) = if self.smash_t > 0.0 {
            (
                Color::rgb(1.0, 0.78, 0.30),
                Color::rgba(1.0, 0.45, 0.10, 0.55),
                5.0,
            )
        } else if self.slow_t > 0.0 {
            (
                Color::rgb(0.70, 0.85, 1.0),
                Color::rgba(0.55, 0.75, 1.0, 0.40),
                3.6,
            )
        } else {
            (Color::WHITE, Color::rgba(1.0, 1.0, 1.0, 0.22), 3.6)
        };
        // Two soft rings stand in for a blurred halo.
        let hr = BALL_R * mult / 2.0;
        d.fill(
            Shape::Ellipse(Rect::new(x - hr, y - hr, 2.0 * hr, 2.0 * hr)),
            halo.with_alpha(halo.a * 0.45),
        );
        let hr2 = hr * 0.7;
        d.fill(
            Shape::Ellipse(Rect::new(x - hr2, y - hr2, 2.0 * hr2, 2.0 * hr2)),
            halo.with_alpha(halo.a * 0.7),
        );
        d.fill(
            Shape::Ellipse(Rect::new(
                x - BALL_R,
                y - BALL_R,
                2.0 * BALL_R,
                2.0 * BALL_R,
            )),
            core,
        );
    }

    fn draw_paddle(&self, d: &mut Draw) {
        let wide = self.wide_t > 0.0;
        let (top, bottom) = if wide {
            (Color::rgb(0.55, 0.85, 1.0), Color::rgb(0.20, 0.55, 0.95))
        } else {
            (Color::rgb(0.70, 0.75, 0.85), Color::rgb(0.45, 0.50, 0.65))
        };
        let (pw, px, py) = (self.paddle_w, self.paddle_x, self.paddle_y);
        if wide {
            d.fill(
                Shape::RoundedRect(
                    Rect::new(
                        px - pw / 2.0 - 7.0,
                        py - PADDLE_H / 2.0 - 5.0,
                        pw + 14.0,
                        PADDLE_H + 10.0,
                    ),
                    8.0,
                ),
                Color::rgba(0.30, 0.70, 0.95, 0.35),
            );
        }
        d.fill(
            Shape::RoundedRect(
                Rect::new(px - pw / 2.0, py - PADDLE_H / 2.0, pw, PADDLE_H),
                6.0,
            ),
            LinearGradient::new(
                UnitPoint::TOP,
                UnitPoint::BOTTOM,
                vec![(0.0, top), (1.0, bottom)],
            ),
        );
        d.fill(
            Shape::RoundedRect(
                Rect::new(
                    px - pw / 2.0 + 3.0,
                    py - PADDLE_H * 0.45,
                    pw - 6.0,
                    PADDLE_H * 0.35,
                ),
                4.0,
            ),
            Color::rgba(1.0, 1.0, 1.0, 0.35),
        );
    }

    /// A power-up timer badge: the letter in a colored disc and a draining bar, in a black
    /// capsule. Advances `x` past itself.
    fn draw_badge(&self, d: &mut Draw, x: &mut f64, kind: Power, frac: f64) {
        let color = kind.color();
        let (bw, bh) = (74.0, 20.0);
        let y = 6.0;
        d.fill(
            Shape::RoundedRect(Rect::new(*x, y, bw, bh), bh / 2.0),
            Color::rgba(0.0, 0.0, 0.0, 0.55),
        );
        d.fill(
            Shape::Ellipse(Rect::new(*x + 6.0, y + 3.0, 14.0, 14.0)),
            color,
        );
        d.text(
            kind.letter(),
            Point::new(*x + 13.0, y + 10.0),
            TextStyle {
                size: 10.0,
                color: Color::WHITE,
                anchor: TextAnchor::CENTERED,
                font: chrome::canvas_font(FontWeight::Heavy),
            },
        );
        let bar = Rect::new(*x + 26.0, y + 7.5, 38.0, 5.0);
        d.fill(
            Shape::RoundedRect(bar, 2.5),
            Color::rgba(1.0, 1.0, 1.0, 0.10),
        );
        d.fill(
            Shape::RoundedRect(
                Rect::new(
                    bar.origin.x,
                    bar.origin.y,
                    bar.size.width * frac.clamp(0.0, 1.0),
                    5.0,
                ),
                2.5,
            ),
            color.with_alpha(0.85),
        );
        *x += bw + 8.0;
    }
}

/// The home-grid tile preview: the REAL renderer over a curated mid-game state, scaled
/// from a 280×320 virtual field into the tile.
pub fn breakout_preview() -> AnyPiece {
    canvas(|d, sz| {
        if sz.width < 4.0 || sz.height < 4.0 {
            return;
        }
        let full = Size::new(280.0, 320.0);
        let mut g = Game::new();
        g.rng = Rng(0x5EED_0001);
        g.setup(full.width, full.height - HUD_H);
        g.level = 2;
        g.build_level();
        // Bite a notch out of the wall and drop the two lowest rows, so the tile reads as a
        // game in progress.
        for i in 0..ROWS * COLS {
            let (r, c) = (i / COLS, i % COLS);
            if r >= 6 || (r == 5 && (3..=5).contains(&c)) || (r == 4 && c == 4) {
                g.bricks[i].hp = 0;
            }
        }
        g.bricks[2 * COLS + 6].power = Some(Power::Multi);
        g.bricks[3 * COLS + 2].power = Some(Power::Wide);
        g.score = 84;
        g.combo = 2;
        g.launched = true;
        g.paddle_x = full.width * 0.44;
        g.ball = Ball {
            x: full.width * 0.56,
            y: g.paddle_y - 46.0,
            dx: 120.0,
            dy: -280.0,
        };
        for k in 1..=5 {
            g.trail
                .push((g.ball.x - 4.0 * k as f64, g.ball.y + 9.0 * k as f64));
        }
        g.update_prediction();
        d.transformed(
            Affine::scale(sz.width / full.width, sz.height / full.height),
            |d| g.draw(d, full),
        );
    })
    .any()
}

// ---------------------------------------------------------------------------
// The page
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Overlay {
    None,
    Pause,
    LevelComplete,
    GameOver,
    Settings,
    Instructions,
}

// Sounds, each with the haptic it plays beside (gamekit::chrome::Cue).
static BRICK_1: Cue = with("sounds/breakout/brick_1.wav", cues::MEDIUM_BEAT);
static BRICK_2: Cue = with("sounds/breakout/brick_2.wav", chrome::THUD);
static BRICK_4: Cue = with("sounds/breakout/brick_4.wav", chrome::CELEBRATE);
const PADDLE: Sfx = sfx("sounds/breakout/paddle.wav");
static POWER: Cue = with("sounds/breakout/power.wav", cues::SUCCESS_BEAT);
static LIFE: Cue = with("sounds/breakout/life.wav", chrome::CELEBRATE);
static SMASH: Cue = with("sounds/breakout/smash.wav", chrome::THUD);
static LEVEL: Cue = with("sounds/breakout/level.wav", chrome::BIG_CELEBRATE);

/// Every clip this game plays besides the shared ones (gamekit preloads both).
pub const SOUNDS: &[Sfx] = &[
    sfx("sounds/breakout/brick_1.wav"),
    sfx("sounds/breakout/brick_2.wav"),
    sfx("sounds/breakout/brick_4.wav"),
    sfx("sounds/breakout/paddle.wav"),
    sfx("sounds/breakout/power.wav"),
    sfx("sounds/breakout/life.wav"),
    sfx("sounds/breakout/smash.wav"),
    sfx("sounds/breakout/level.wav"),
];

struct Ui {
    game: Rc<RefCell<Game>>,
    /// The play layer: every frame while the game runs.
    repaint: Trigger,
    /// The wall layer: when a brick is hit, a level starts, or the field resizes.
    wall: Trigger,
    /// The HUD layer: when the score, lives, or level change.
    hud: Trigger,
    /// What the layers were last told, so a tick notifies only the ones that changed.
    seen_wall: Cell<u32>,
    seen_hud: Cell<(i64, i32, i32)>,
    overlay: Signal<Overlay>,
    sounds: Signal<bool>,
    vibrations: Signal<bool>,
    /// A pointer is inside the paddle's travel band: the paddle follows it and the cursor
    /// hides. Only pointer devices hover, so this stays false on a phone.
    pointer_in_band: Signal<bool>,
    /// A pointer has hovered this field at least once — so a press is a click, not a finger,
    /// and the paddle sits under it rather than lifted above it.
    pointer_seen: Cell<bool>,
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
    /// Re-record the layers whose inputs changed since the last look.
    fn sync_layers(&self) {
        let (wall, hud) = {
            let g = self.game.borrow();
            (g.wall_version, (g.score, g.lives, g.level))
        };
        if self.seen_wall.replace(wall) != wall {
            self.wall.notify();
        }
        if self.seen_hud.replace(hud) != hud {
            self.hud.notify();
        }
    }

    fn show(&self, kind: Overlay) {
        self.overlay.set(kind);
        self.repaint.notify();
        self.sync_layers();
    }

    /// The pause menu, when there is a live game to pause.
    fn pause(&self) {
        if self.overlay.get_untracked() == Overlay::None {
            let g = self.game.borrow();
            if !g.game_over && !g.level_complete {
                drop(g);
                self.show(Overlay::Pause);
            }
        }
    }

    fn new_game(&self) {
        self.game.borrow_mut().new_game();
        gamekit::clear(SAVE_KEY);
        self.show(Overlay::None);
        self.cue(&cues::START);
    }
}

/// The Breakout screen.
pub fn breakout_page() -> AnyPiece {
    let settings = gamekit::restore::<chrome::GameSettings>(SETTINGS_KEY).unwrap_or_default();
    let mut game = Game::new();
    game.best = gamekit::restore::<i64>(RECORD_KEY).unwrap_or(0);
    let mut resumed = false;
    if let Some(s) = gamekit::restore::<SaveState>(SAVE_KEY) {
        game.apply_save(s);
        resumed = game.launched && !game.game_over && !game.level_complete;
    }
    let ui = Rc::new(Ui {
        game: Rc::new(RefCell::new(game)),
        repaint: Trigger::new(),
        wall: Trigger::new(),
        hud: Trigger::new(),
        seen_wall: Cell::new(0),
        seen_hud: Cell::new((-1, -1, -1)),
        overlay: Signal::new(Overlay::None),
        sounds: Signal::new(settings.sounds),
        vibrations: Signal::new(settings.vibrations),
        pointer_in_band: Signal::new(false),
        pointer_seen: Cell::new(false),
    });
    gamekit::autosave(SAVE_KEY, {
        let game = ui.game.clone();
        move || game.borrow().save_state()
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
    // A game restored mid-flight waits behind the pause menu (the player was not holding the
    // paddle when it left); the first launch opens the rules instead.
    if !settings.instructions_shown {
        ui.show(Overlay::Instructions);
    } else if resumed {
        ui.show(Overlay::Pause);
    } else {
        let g = ui.game.borrow();
        if g.game_over {
            drop(g);
            ui.show(Overlay::GameOver);
        } else if g.level_complete {
            drop(g);
            ui.show(Overlay::LevelComplete);
        }
    }
    gamekit::on_background(SAVE_KEY, {
        let ui = ui.clone();
        move || {
            if ui.game.borrow().live() {
                ui.pause();
            }
        }
    });

    // Four layers, each re-recorded on its own trigger (see `Game::draw`). Every layer
    // fills the same frame, and every one calls `setup` so the first of them to be laid
    // out sizes the field for the rest.
    let backdrop = {
        let du = ui.clone();
        canvas(move |d, sz| {
            du.game
                .borrow_mut()
                .setup(sz.width, (sz.height - HUD_H).max(10.0));
            du.game.borrow().draw_backdrop(d, sz);
        })
        .grow()
    };
    let wall = {
        let du = ui.clone();
        canvas(move |d, sz| {
            du.wall.track();
            du.game
                .borrow_mut()
                .setup(sz.width, (sz.height - HUD_H).max(10.0));
            d.transformed(Affine::translate(0.0, HUD_H), |d| {
                du.game.borrow().draw_wall(d)
            });
        })
        .grow()
    };
    let hud = {
        let du = ui.clone();
        canvas(move |d, sz| {
            du.hud.track();
            du.game.borrow().draw_hud(d, sz.width);
        })
        .height(HUD_H)
        .grow_w()
    };
    let field = {
        let (du, dr, hu, cu, tu, ku) = (
            ui.clone(),
            ui.clone(),
            ui.clone(),
            ui.clone(),
            ui.clone(),
            ui.clone(),
        );
        canvas(move |d, sz| {
            du.repaint.track();
            du.game
                .borrow_mut()
                .setup(sz.width, (sz.height - HUD_H).max(10.0));
            d.transformed(Affine::translate(0.0, HUD_H), |d| {
                du.game.borrow().draw_play(d)
            });
        })
        // A mouse, trackpad, or pen steers the paddle by moving over the field — no press
        // needed — and the cursor hides while it is in the paddle's band. Touch never hovers
        // (docs/canvas.md), so a finger keeps the drag below.
        .on_hover(move |at| {
            hu.pointer_seen.set(true);
            let mut in_band = false;
            if let Some(p) = at
                && hu.overlay.get_untracked() == Overlay::None
            {
                let mut g = hu.game.borrow_mut();
                if !g.game_over && !g.level_complete {
                    in_band = g.set_pointer_target(p.x, p.y - HUD_H);
                }
            }
            if hu.pointer_in_band.get_untracked() != in_band {
                hu.pointer_in_band.set(in_band);
            }
        })
        .cursor(move || {
            if cu.pointer_in_band.get() {
                Cursor::None
            } else {
                Cursor::Default
            }
        })
        .on_drag(move |dg| {
            if dr.overlay.get_untracked() != Overlay::None {
                return;
            }
            let mut g = dr.game.borrow_mut();
            if g.game_over || g.level_complete {
                return;
            }
            let launched = g.launched;
            g.launch();
            if dr.pointer_seen.get() {
                g.set_pointer_target(dg.location.x, dg.location.y - HUD_H);
            } else {
                g.set_target(dg.location.x, dg.location.y - HUD_H);
            }
            drop(g);
            if !launched {
                dr.haptic(Haptic::Light);
            }
        })
        .on_tap(move || {
            if tu.overlay.get_untracked() != Overlay::None {
                return;
            }
            let mut g = tu.game.borrow_mut();
            let launched = g.launched;
            g.launch();
            drop(g);
            if !launched {
                tu.haptic(Haptic::Light);
            }
        })
        .on_key(move |k| {
            let mut g = ku.game.borrow_mut();
            match k.key.as_str() {
                "ArrowLeft" => g.nudge_target(-KEY_STEP),
                "ArrowRight" => g.nudge_target(KEY_STEP),
                "ArrowUp" => g.launch(),
                _ => {}
            }
        })
        .id("bk-canvas")
        .grow()
    };

    // Mounted only while the game is live, so the display link goes idle behind a card.
    let clock = {
        let (cu, bu) = (ui.clone(), ui.clone());
        when(
            move || cu.overlay.get() == Overlay::None,
            move || breakout_clock(bu.clone()),
        )
    };

    let pause = chrome::pause_button(tr("gk_pause"), "bk-pause", {
        let ui = ui.clone();
        move || {
            ui.pause();
            ui.cue(&cues::SELECT);
        }
    })
    .padding(Insets {
        top: 0.0,
        leading: 0.0,
        bottom: 0.0,
        trailing: 4.0,
    });

    zstack((
        backdrop,
        wall,
        field,
        // The HUD strip sits on top so a particle never crosses the numbers, aligned to the
        // top of the stack (the full-size layers are unaffected by the alignment).
        hud.overlay_aligned(Alignment::TopTrailing, pause),
        overlays(ui),
        clock,
    ))
    .align(Alignment::Top)
    .any()
}

/// The game's frame consumer: paddle easing, the physics step, then the haptics and cards
/// the tick earned, then the layers that changed.
fn breakout_clock(ui: Rc<Ui>) -> impl Piece {
    frame_clock(move |dt| {
        let dt = dt.as_secs_f64();
        let happenings = {
            let mut g = ui.game.borrow_mut();
            g.step_paddle(dt);
            g.update(dt);
            std::mem::take(&mut g.happenings)
        };
        for h in happenings {
            match h {
                Happening::Launched => ui.cue(&cues::PLUCK),
                // A break in a combo lands harder the longer the run.
                Happening::BrickBroken(combo) => ui.cue(match combo {
                    1 => &BRICK_1,
                    2 | 3 => &BRICK_2,
                    _ => &BRICK_4,
                }),
                // A flat bounce thuds and rings loudest; a sharp deflection is the lightest tick.
                Happening::PaddleHit(deflection) => {
                    let (h, volume) = if deflection < 0.15 {
                        (Haptic::Heavy, 1.0)
                    } else if deflection < 0.5 {
                        (Haptic::Medium, 0.75)
                    } else {
                        (Haptic::Light, 0.5)
                    };
                    ui.haptic(h);
                    chrome::sound(ui.sounds.get_untracked(), &PADDLE, volume);
                }
                Happening::Caught(Power::ExtraLife) => ui.cue(&LIFE),
                Happening::Caught(Power::Smash) => ui.cue(&SMASH),
                Happening::Caught(_) => ui.cue(&POWER),
                Happening::LifeLost => ui.cue(&cues::LETDOWN),
                Happening::LevelComplete => {
                    ui.cue(&LEVEL);
                    ui.show(Overlay::LevelComplete);
                }
                Happening::GameOver => {
                    ui.cue(&cues::OVER_ARCADE);
                    ui.show(Overlay::GameOver);
                }
            }
        }
        ui.repaint.notify();
        ui.sync_layers();
    })
}

fn overlays(ui: Rc<Ui>) -> impl Piece {
    let scrim = {
        let u = ui.clone();
        when(move || u.overlay.get() != Overlay::None, chrome::scrim)
    };
    let (p, l, g, s, i) = (ui.clone(), ui.clone(), ui.clone(), ui.clone(), ui.clone());
    let card = move |kind: Overlay, build: Rc<dyn Fn() -> AnyPiece>| {
        let u = ui.clone();
        when(move || u.overlay.get() == kind, move || build())
    };
    zstack((
        scrim,
        card(Overlay::Pause, Rc::new(move || pause_menu(p.clone()))),
        card(
            Overlay::LevelComplete,
            Rc::new(move || level_complete_card(l.clone())),
        ),
        card(
            Overlay::GameOver,
            Rc::new(move || game_over_card(g.clone())),
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
            chrome::menu_button(tr("gk_resume"), chrome::GREEN, "bk-resume", move || {
                u1.show(Overlay::None)
            }),
            chrome::menu_button(tr("gk_new_game"), chrome::BLUE, "bk-new-game", move || {
                u2.new_game()
            }),
            chrome::menu_button(tr("gk_settings"), chrome::SLATE, "bk-settings", move || {
                u3.show(Overlay::Settings)
            }),
            chrome::menu_button(
                tr("gk_instructions"),
                chrome::INDIGO,
                "bk-instructions",
                move || u4.show(Overlay::Instructions),
            ),
            chrome::menu_button(tr("gk_quit"), chrome::RED, "bk-quit", || {
                nav_back();
            }),
        ))
        .spacing(14.0)
        .align(HAlign::Center),
    )
    .id("bk-pause-menu")
    .any()
}

fn level_complete_card(ui: Rc<Ui>) -> AnyPiece {
    let (level, score) = {
        let g = ui.game.borrow();
        (g.level, g.score)
    };
    let u = ui;
    chrome::card(
        column((
            chrome::card_title(tr("bk_level_clear").arg("n", level as i64), chrome::GOLD),
            chrome::stat(
                tr("gk_score"),
                score.to_string(),
                Font::LargeTitle,
                Color::WHITE,
                "bk-clear-score",
            ),
            chrome::menu_button(
                tr("bk_next_level"),
                chrome::GREEN,
                "bk-next-level",
                move || {
                    let next = u.game.borrow().level + 1;
                    u.game.borrow_mut().start_level(next);
                    gamekit::clear(SAVE_KEY);
                    u.show(Overlay::None);
                    u.cue(&cues::START);
                },
            ),
        ))
        .spacing(16.0)
        .align(HAlign::Center),
    )
    .id("bk-level-complete")
    .any()
}

fn game_over_card(ui: Rc<Ui>) -> AnyPiece {
    let (score, level, best) = {
        let g = ui.game.borrow();
        (g.score, g.level, g.best)
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
            chrome::stat(
                tr("gk_score"),
                score.to_string(),
                Font::LargeTitle,
                chrome::GOLD,
                "bk-final-score",
            ),
            row((
                chrome::stat(
                    tr("bk_level_caption"),
                    level.to_string(),
                    Font::Title3,
                    Color::WHITE,
                    "bk-final-level",
                ),
                chrome::stat(
                    tr("gk_best"),
                    best.to_string(),
                    Font::Title3,
                    Color::WHITE,
                    "bk-best",
                ),
            ))
            .spacing(24.0),
            record,
            chrome::menu_button(
                tr("gk_play_again"),
                chrome::BLUE,
                "bk-play-again",
                move || u.new_game(),
            ),
            chrome::menu_button(tr("gk_quit"), chrome::RED, "bk-quit", || {
                nav_back();
            }),
        ))
        .spacing(14.0)
        .align(HAlign::Center),
    )
    .id("bk-game-over")
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
                        u.game.borrow_mut().best = 0;
                        gamekit::clear(RECORD_KEY);
                        u.repaint.notify();
                    }
                });
            })
            .id("bk-reset-high-score")
    };
    let done = ui.clone();
    chrome::card(
        column((
            label(tr("gk_settings"))
                .font(Font::Title2)
                .bold()
                .color(Color::WHITE),
            chrome::section_heading(tr("nav_breakout")),
            chrome::setting_row(tr("gk_sounds"), toggle(ui.sounds).id("bk-sounds").any()),
            chrome::setting_row(
                tr("gk_vibrations"),
                toggle(ui.vibrations).id("bk-vibrations").any(),
            ),
            chrome::section_heading(tr("gk_data")),
            reset,
            button(tr("gk_done"))
                .prominent()
                .action(move || done.show(Overlay::Pause))
                .id("bk-done"),
        ))
        .spacing(12.0)
        .align(HAlign::Center),
    )
    .id("bk-settings-card")
    .any()
}

fn instructions_card(ui: Rc<Ui>) -> AnyPiece {
    // Done returns to the pause menu when the game is paused, else to the board.
    let live = ui.game.borrow().live();
    chrome::instructions_card(
        tr("nav_breakout"),
        vec![
            Help::Para(tr("bk_help_intro")),
            Help::Heading(tr("bk_help_play")),
            Help::Para(tr("bk_help_play_1")),
            Help::Para(tr("bk_help_play_2")),
            Help::Para(tr("bk_help_play_3")),
            Help::Heading(tr("bk_help_powerups")),
            Help::Para(tr("bk_help_powerups_1")),
            Help::Heading(tr("bk_help_lives")),
            Help::Para(tr("bk_help_lives_1")),
        ],
        "bk-help-done",
        move || ui.show(if live { Overlay::Pause } else { Overlay::None }),
    )
    .id("bk-instructions-card")
    .any()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn game_400x700() -> Game {
        let mut g = Game::new();
        g.rng = Rng(0xC0FFEE);
        g.setup(400.0, 700.0);
        g.new_game();
        g
    }

    fn drain(g: &mut Game) -> Vec<Happening> {
        std::mem::take(&mut g.happenings)
    }

    #[test]
    fn launch_starts_the_ball_upward() {
        let mut g = game_400x700();
        assert!(!g.launched);
        g.launch();
        assert!(g.launched && g.ball.dy < 0.0);
        assert!(drain(&mut g).contains(&Happening::Launched));
    }

    #[test]
    fn paddle_eases_toward_the_target_without_teleporting() {
        let mut g = game_400x700();
        g.set_target(350.0, 600.0);
        g.step_paddle(1.0 / 60.0);
        let moved = g.paddle_x - 200.0;
        assert!(
            moved > 0.0 && moved < 150.0,
            "one frame moves part way: {moved}"
        );
        for _ in 0..60 {
            g.step_paddle(1.0 / 60.0);
        }
        assert!((g.paddle_x - 350.0).abs() < 0.5);
        assert!(g.paddle_y >= g.paddle_y_min() && g.paddle_y <= g.paddle_y_max());
        assert!(
            (g.ball.x - g.paddle_x).abs() < 0.01,
            "the parked ball rode along"
        );
    }

    #[test]
    fn a_pointer_steers_only_inside_the_paddle_band() {
        let mut g = game_400x700();
        assert!(!g.set_pointer_target(100.0, 50.0), "over the wall: ignored");
        assert_eq!(g.target_x, 200.0);
        assert!(g.set_pointer_target(100.0, 600.0));
        assert_eq!(g.target_x, 100.0);
        assert_eq!(g.target_y, 600.0, "no lift under a cursor");
    }

    #[test]
    fn fast_paddle_never_passes_through_the_ball() {
        let mut g = game_400x700();
        g.launch();
        // A ball drifting down toward the paddle …
        g.ball = Ball {
            x: 200.0,
            y: g.paddle_y - 30.0,
            dx: 0.0,
            dy: 50.0,
        };
        // … while the paddle lunges straight up past it in one tick.
        g.prev_py = g.paddle_y;
        g.paddle_y -= 60.0;
        let dt = 1.0 / 60.0;
        let mut b = g.ball;
        let lost = g.step_ball(&mut b, dt, 1.0, true);
        assert!(!lost);
        assert!(b.dy < 0.0, "knocked upward, dy = {}", b.dy);
        assert!(
            b.y + BALL_R <= g.paddle_y - PADDLE_H / 2.0 + 0.6,
            "carried on top"
        );
        assert!(
            drain(&mut g)
                .iter()
                .any(|h| matches!(h, Happening::PaddleHit(_)))
        );
    }

    #[test]
    fn breaking_bricks_scores_with_combo_and_drops_the_carried_power_up() {
        let mut g = game_400x700();
        g.launch();
        let i = (0..ROWS * COLS)
            .find(|&i| g.bricks[i].power.is_some())
            .unwrap();
        g.bricks[i].hp = 1;
        let rect = g.brick_rect(i);
        let mut b = Ball {
            x: rect.origin.x + rect.size.width / 2.0,
            y: rect.origin.y + rect.size.height + BALL_R - 1.0,
            dx: 0.0,
            dy: -100.0,
        };
        g.hit_bricks(&mut b, true);
        assert!(!g.bricks[i].alive());
        assert_eq!(g.combo, 1);
        assert_eq!(g.score, ROW_POINTS[i / COLS]);
        assert_eq!(g.drops.len(), 1, "the carried power-up falls");
        assert!(b.dy > 0.0, "reflected downward");
        // A second break inside the combo window doubles.
        let j = (0..ROWS * COLS)
            .find(|&j| g.bricks[j].alive() && j / COLS == i / COLS)
            .unwrap();
        g.bricks[j].hp = 1;
        let before = g.score;
        let rect = g.brick_rect(j);
        let mut b2 = Ball {
            x: rect.origin.x + rect.size.width / 2.0,
            y: rect.origin.y + rect.size.height + BALL_R - 1.0,
            dx: 0.0,
            dy: -100.0,
        };
        g.hit_bricks(&mut b2, true);
        assert_eq!(g.score - before, ROW_POINTS[j / COLS] * 2);
    }

    #[test]
    fn armored_bricks_take_several_hits_on_later_levels() {
        let mut g = game_400x700();
        g.start_level(4);
        assert_eq!(g.bricks[0].hp, 3);
        assert_eq!(g.bricks[COLS].hp, 2);
        assert_eq!(g.bricks[2 * COLS].hp, 1);
        g.on_brick_hit(0, true);
        assert_eq!(g.bricks[0].hp, 2);
        assert_eq!(g.score, 1, "a dent scores one");
        assert!(g.combo == 0);
    }

    #[test]
    fn multi_ball_splits_once_and_promotes_an_extra_on_loss() {
        let mut g = game_400x700();
        g.launch();
        g.apply_power(Power::Multi, 200.0, 500.0);
        assert_eq!(g.extras.len(), 2);
        assert_eq!(g.score, CATCH_SCORE);
        // Lose the primary: an extra takes over and no life is lost.
        g.ball.y = g.field.height + 50.0;
        g.ball.dy = 10.0;
        let lives = g.lives;
        g.update(1.0 / 60.0);
        assert_eq!(g.lives, lives);
        assert_eq!(g.extras.len(), 1);
    }

    #[test]
    fn losing_the_last_ball_costs_a_life_then_the_game() {
        let mut g = game_400x700();
        g.lives = 1;
        g.launch();
        g.wide_t = 5.0;
        g.ball.y = g.field.height + 50.0;
        g.ball.dy = 10.0;
        g.update(1.0 / 60.0);
        assert!(g.game_over);
        assert_eq!(g.wide_t, 0.0, "effects end with the life");
        assert!(drain(&mut g).contains(&Happening::GameOver));
    }

    #[test]
    fn clearing_the_wall_completes_the_level_and_records_the_best() {
        let mut g = game_400x700();
        g.launch();
        for b in g.bricks.iter_mut() {
            b.hp = 0;
        }
        g.score = 120;
        g.update(1.0 / 60.0);
        assert!(g.level_complete);
        assert_eq!(g.best, 120);
        assert!(drain(&mut g).contains(&Happening::LevelComplete));
        g.start_level(2);
        assert!(!g.level_complete && !g.launched);
        assert_eq!(g.level, 2);
        assert!(g.bricks.iter().all(|b| b.alive()));
    }

    #[test]
    fn smash_ball_passes_through_bricks() {
        let mut g = game_400x700();
        g.launch();
        g.smash_t = 5.0;
        let rect = g.brick_rect(3 * COLS + 4);
        let mut b = Ball {
            x: rect.origin.x + rect.size.width / 2.0,
            y: rect.origin.y + rect.size.height / 2.0,
            dx: 0.0,
            dy: -300.0,
        };
        g.hit_bricks(&mut b, true);
        assert!(!g.bricks[3 * COLS + 4].alive());
        assert!(b.dy < 0.0, "still travelling upward");
    }

    #[test]
    fn save_restore_keeps_the_wall_and_progress() {
        let mut g = game_400x700();
        g.launch();
        g.bricks[5].hp = 0;
        g.score = 33;
        g.level = 2;
        let s = g.save_state();
        let json = serde_json::to_string(&s).unwrap();
        let back: SaveState = serde_json::from_str(&json).unwrap();
        let mut g2 = game_400x700();
        g2.apply_save(back);
        assert!(!g2.bricks[5].alive());
        assert!(g2.bricks[6].alive());
        assert_eq!(g2.score, 33);
        assert_eq!(g2.level, 2);
        assert!(g2.launched);
        assert!(g2.extras.is_empty() && g2.drops.is_empty());
    }
}
