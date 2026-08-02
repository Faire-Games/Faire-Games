//! Breakout — a real-time brick-breaker drawn on an immediate-mode canvas and driven by Day's frame
//! clock (§8.4). A composite Day piece: pure composition over `day_pieces`, so it renders on every
//! backend. The paddle follows a 2-D drag; balls integrate dt-based physics each vsync; bricks can
//! drop catchable power-ups.

use std::cell::RefCell;
use std::rc::Rc;

use day_fluent::tr;
use day_pieces::prelude::*;
use serde::{Deserialize, Serialize};

/// The prefs key this game's state persists under (gamekit; bump on schema change).
const SAVE_KEY: &str = "breakout.v1";

// --- tuning ---------------------------------------------------------------
const ROWS: usize = 6;
const COLS: usize = 8;
const BRICK_GAP: f64 = 4.0;
const BRICK_TOP: f64 = 70.0;
const BRICK_H: f64 = 20.0;
const SIDE: f64 = 8.0; // wall inset
/// Leading gutter for the top-left HUD, clear of the cover's close button.
const CLOSE_GUTTER: f64 = 44.0;
const PADDLE_W: f64 = 92.0;
const PADDLE_WIDE_W: f64 = 148.0;
const PADDLE_H: f64 = 14.0;
const PADDLE_UP: f64 = 44.0; // paddle centre this far above the field bottom (rest position)
const PADDLE_LIFT: f64 = 52.0; // paddle rides this far above the finger, so it stays visible
const BALL_R: f64 = 7.0;
const BASE_SPEED: f64 = 340.0; // px/s at level 1
const MAX_BALLS: usize = 7;

// Power-ups (docs mirror Faire-Games): timed effects + instant ones.
const WIDE_DUR: f64 = 14.0;
const SLOW_DUR: f64 = 13.0;
const SMASH_DUR: f64 = 8.0;
const SLOW_FACTOR: f64 = 0.6;
const PU_FALL: f64 = 150.0; // power-up fall speed (px/s)
const PU_R: f64 = 15.0; // power-up capsule radius
const PU_DROP_CHANCE: f64 = 0.06; // extra random drop per destroyed brick

/// A tiny xorshift RNG — no `rand` dependency, deterministic per instance.
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
}

#[derive(Clone, Copy, PartialEq, Serialize, Deserialize)]
enum Power {
    Wide,
    Multi,
    Slow,
    ExtraLife,
    Smash,
}

impl Power {
    fn from_index(i: u64) -> Power {
        match i % 5 {
            0 => Power::Wide,
            1 => Power::Multi,
            2 => Power::Slow,
            3 => Power::ExtraLife,
            _ => Power::Smash,
        }
    }
    fn color(self) -> Color {
        match self {
            Power::Wide => Color::hex(0x22_D3_EE),
            Power::Multi => Color::hex(0xE8_79_F9),
            Power::Slow => Color::hex(0x60_A5_FA),
            Power::ExtraLife => Color::hex(0x34_D3_99),
            Power::Smash => Color::hex(0xF5_9E_0B),
        }
    }
    fn glyph(self) -> &'static str {
        match self {
            Power::Wide => "W",
            Power::Multi => "M",
            Power::Slow => "S",
            Power::ExtraLife => "+1",
            Power::Smash => "*",
        }
    }
}

#[derive(Clone, Copy)]
struct Ball {
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
}

struct Drop {
    x: f64,
    y: f64,
    kind: Power,
}

struct Particle {
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    life: f64,
    max: f64,
    color: Color,
}

struct Game {
    field: Size,
    bricks: Vec<u8>,             // ROWS*COLS, hp (0 = cleared)
    powered: Vec<Option<Power>>, // ROWS*COLS, a brick pre-loaded with a power-up
    paddle_x: f64,
    paddle_y: f64,
    balls: Vec<Ball>,
    launched: bool,
    score: i64,
    best: i64,
    lives: i32,
    level: i32,
    game_over: bool,
    particles: Vec<Particle>,
    drops: Vec<Drop>,
    wide_t: f64,
    slow_t: f64,
    smash_t: f64,
    /// The last brick broke mid-physics-step. The level advance (which RESETS `balls`) is
    /// deferred to the end of [`Game::step`] — mutating the ball list inside the integration
    /// loop is an out-of-bounds panic.
    level_cleared: bool,
    rng: Rng,
}

/// The durable subset of [`Game`] (gamekit save/restore): the board, progress, and best
/// score. Balls in flight, particles, drops, and power-up timers are session-only — a
/// restored game parks the ball on the paddle, ready to launch.
#[derive(Serialize, Deserialize)]
struct SaveState {
    bricks: Vec<u8>,
    powered: Vec<Option<Power>>,
    score: i64,
    best: i64,
    lives: i32,
    level: i32,
}

/// Rainbow row palette (top row hottest), matching the classic look.
fn row_color(row: usize) -> Color {
    Color::hsl(8.0 + row as f64 * 40.0, 0.72, 0.55)
}

fn row_points(row: usize) -> i64 {
    (ROWS - row) as i64 // top rows worth more
}

impl Game {
    fn new() -> Self {
        let seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0x9E37_79B9_7F4A_7C15)
            | 1;
        let mut g = Game {
            field: Size::new(0.0, 0.0),
            bricks: vec![1; ROWS * COLS],
            powered: vec![None; ROWS * COLS],
            paddle_x: 0.0,
            paddle_y: 0.0,
            balls: Vec::new(),
            launched: false,
            score: 0,
            best: 0,
            lives: 3,
            level: 1,
            game_over: false,
            particles: Vec::new(),
            drops: Vec::new(),
            wide_t: 0.0,
            slow_t: 0.0,
            smash_t: 0.0,
            level_cleared: false,
            rng: Rng(seed),
        };
        g.reset_bricks();
        g
    }

    fn reset_bricks(&mut self) {
        for row in 0..ROWS {
            for col in 0..COLS {
                let hp = if self.level >= 3 && row >= ROWS - 1 {
                    2
                } else {
                    1
                };
                self.bricks[row * COLS + col] = hp;
            }
        }
        // Pre-load 3–4 random bricks with power-ups (one guaranteed multi + extra-life feel varied).
        self.powered = vec![None; ROWS * COLS];
        let n = 3 + (self.rng.next() % 2) as usize;
        for _ in 0..n {
            let idx = (self.rng.next() as usize) % (ROWS * COLS);
            self.powered[idx] = Some(Power::from_index(self.rng.next()));
        }
    }

    fn speed(&self) -> f64 {
        BASE_SPEED + (self.level - 1) as f64 * 26.0
    }

    fn paddle_w(&self) -> f64 {
        if self.wide_t > 0.0 {
            PADDLE_WIDE_W
        } else {
            PADDLE_W
        }
    }

    fn paddle_rest_y(&self) -> f64 {
        self.field.height - PADDLE_UP
    }

    /// Park a single ball on the paddle, ready to launch.
    fn rest_ball(&mut self) {
        self.balls.clear();
        self.launched = false;
    }

    fn resting_ball_pos(&self) -> (f64, f64) {
        (self.paddle_x, self.paddle_y - PADDLE_H / 2.0 - BALL_R - 1.0)
    }

    fn launch(&mut self) {
        if self.game_over || self.launched {
            return;
        }
        let (x, y) = self.resting_ball_pos();
        let ang = self.rng.range(-0.4, 0.4); // radians from straight up
        let s = self.speed();
        self.balls.push(Ball {
            x,
            y,
            vx: s * ang.sin(),
            vy: -s * ang.cos(),
        });
        self.launched = true;
    }

    fn restart(&mut self) {
        self.score = 0;
        self.lives = 3;
        self.level = 1;
        self.game_over = false;
        self.level_cleared = false;
        self.particles.clear();
        self.drops.clear();
        self.wide_t = 0.0;
        self.slow_t = 0.0;
        self.smash_t = 0.0;
        self.reset_bricks();
        self.paddle_y = self.paddle_rest_y();
        self.rest_ball();
    }

    /// Snapshot the durable state (gamekit). A finished game saves only the best score —
    /// restoring it should offer a fresh board, not a dead one.
    fn save_state(&self) -> SaveState {
        if self.game_over {
            return SaveState {
                bricks: vec![1; ROWS * COLS],
                powered: vec![None; ROWS * COLS],
                score: 0,
                best: self.best,
                lives: 3,
                level: 1,
            };
        }
        SaveState {
            bricks: self.bricks.clone(),
            powered: self.powered.clone(),
            score: self.score,
            best: self.best,
            lives: self.lives,
            level: self.level,
        }
    }

    /// Rebuild from a snapshot: board + progress back, ball parked on the paddle.
    fn apply_save(&mut self, s: SaveState) {
        if s.bricks.len() == ROWS * COLS && s.powered.len() == ROWS * COLS {
            self.bricks = s.bricks;
            self.powered = s.powered;
        }
        self.score = s.score;
        self.best = s.best.max(s.score);
        self.lives = s.lives.clamp(1, 5);
        self.level = s.level.max(1);
        self.game_over = false;
        self.level_cleared = false;
        self.rest_ball();
    }

    fn spawn_burst(&mut self, x: f64, y: f64, color: Color, n: usize) {
        for _ in 0..n {
            let a = self.rng.range(0.0, std::f64::consts::TAU);
            let sp = self.rng.range(70.0, 190.0);
            let max = self.rng.range(0.35, 0.75);
            self.particles.push(Particle {
                x,
                y,
                vx: sp * a.cos(),
                vy: sp * a.sin(),
                life: max,
                max,
                color,
            });
        }
    }

    /// Move the paddle in 2-D to follow the finger (like Faire-Games): horizontal free within the
    /// walls, vertical anywhere from the bottom up to the middle of the screen. A SWEPT test keeps
    /// the paddle from ever passing through a ball when it lunges upward.
    fn set_paddle(&mut self, x: f64, y: f64) {
        let old_py = self.paddle_y;
        let half = self.paddle_w() / 2.0;
        let min_x = half + SIDE;
        let max_x = (self.field.width - half - SIDE).max(min_x);
        self.paddle_x = x.clamp(min_x, max_x);
        self.paddle_y = (y - PADDLE_LIFT).clamp(self.field.height * 0.5, self.paddle_rest_y());

        if !self.launched {
            return;
        }
        // The paddle's top edge swept from `old_top` to `new_top`. Any ball that was above the old
        // top and is now reached by the new top gets carried on top of the paddle (never tunnels).
        let speed = self.speed();
        let px = self.paddle_x;
        let pw = self.paddle_w();
        let old_top = old_py - PADDLE_H / 2.0;
        let new_top = self.paddle_y - PADDLE_H / 2.0;
        if new_top >= old_top {
            return; // only an upward lunge can overtake a ball
        }
        for ball in &mut self.balls {
            if (ball.x - px).abs() > pw / 2.0 + BALL_R {
                continue;
            }
            let ball_bottom = ball.y + BALL_R;
            let was_above = ball_bottom <= old_top + BALL_R * 0.5;
            let now_reached = new_top <= ball_bottom;
            if was_above && now_reached {
                ball.y = new_top - BALL_R;
                let hit = ((ball.x - px) / (pw / 2.0)).clamp(-1.0, 1.0);
                let ang = hit * 1.05;
                ball.vx = speed * ang.sin();
                ball.vy = -speed * ang.cos();
            }
        }
    }

    fn catch(&mut self, kind: Power) {
        self.score += 50;
        match kind {
            Power::Wide => self.wide_t = WIDE_DUR,
            Power::Slow => self.slow_t = SLOW_DUR,
            Power::Smash => self.smash_t = SMASH_DUR,
            Power::ExtraLife => {
                self.lives = (self.lives + 1).min(5);
                let (px, py) = (self.paddle_x, self.paddle_y);
                self.spawn_burst(px, py, Power::ExtraLife.color(), 14);
            }
            Power::Multi => {
                // Split every live ball into three (±0.32 rad), capped.
                let extra: Vec<Ball> = self
                    .balls
                    .iter()
                    .flat_map(|b| {
                        let sp = (b.vx * b.vx + b.vy * b.vy).sqrt();
                        let a0 = b.vy.atan2(b.vx);
                        [a0 - 0.32, a0 + 0.32].map(|a| Ball {
                            x: b.x,
                            y: b.y,
                            vx: sp * a.cos(),
                            vy: sp * a.sin(),
                        })
                    })
                    .collect();
                for b in extra {
                    if self.balls.len() >= MAX_BALLS {
                        break;
                    }
                    self.balls.push(b);
                }
            }
        }
    }

    fn step(&mut self, dt: f64) {
        let (w, h) = (self.field.width, self.field.height);
        if w < 10.0 || h < 10.0 {
            return; // not laid out yet
        }
        self.wide_t = (self.wide_t - dt).max(0.0);
        self.slow_t = (self.slow_t - dt).max(0.0);
        self.smash_t = (self.smash_t - dt).max(0.0);

        // Particles.
        let mut i = 0;
        while i < self.particles.len() {
            let p = &mut self.particles[i];
            p.vy += 240.0 * dt;
            p.x += p.vx * dt;
            p.y += p.vy * dt;
            p.life -= dt;
            if p.life <= 0.0 {
                self.particles.swap_remove(i);
            } else {
                i += 1;
            }
        }

        // Falling power-ups: descend, catch on paddle overlap, drop off the bottom.
        let half = self.paddle_w() / 2.0;
        let mut i = 0;
        while i < self.drops.len() {
            self.drops[i].y += PU_FALL * dt;
            let d = &self.drops[i];
            let caught = (d.x - self.paddle_x).abs() <= half + PU_R
                && (d.y - self.paddle_y).abs() <= PADDLE_H / 2.0 + PU_R;
            if caught {
                let kind = d.kind;
                self.drops.swap_remove(i);
                self.catch(kind);
            } else if self.drops[i].y - PU_R > h {
                self.drops.swap_remove(i);
            } else {
                i += 1;
            }
        }

        if self.game_over || !self.launched {
            return;
        }

        // Advance every ball; drop any that fall below the field.
        let mut i = 0;
        while i < self.balls.len() {
            let mut ball = self.balls[i];
            let alive = self.step_ball(&mut ball, dt, w, h);
            if alive {
                self.balls[i] = ball;
                i += 1;
            } else {
                self.balls.swap_remove(i);
            }
        }
        if self.level_cleared {
            // The last brick broke this step: next level, ball parked on the paddle. This
            // runs after the ball loop, and instead of the lost-ball check below.
            self.level_cleared = false;
            self.level += 1;
            self.reset_bricks();
            self.rest_ball();
        } else if self.balls.is_empty() {
            self.lives -= 1;
            if self.lives <= 0 {
                self.game_over = true;
            } else {
                self.rest_ball();
            }
        }
    }

    /// Integrate one ball with sub-stepping; returns false if it fell below the field.
    fn step_ball(&mut self, ball: &mut Ball, dt: f64, w: f64, h: f64) -> bool {
        let slow = if self.slow_t > 0.0 { SLOW_FACTOR } else { 1.0 };
        let eff_dt = dt * slow;
        let dist = (ball.vx * ball.vx + ball.vy * ball.vy).sqrt() * eff_dt;
        let steps = (dist / (BALL_R * 0.9)).ceil().clamp(1.0, 8.0) as usize;
        let sub = eff_dt / steps as f64;
        for _ in 0..steps {
            ball.x += ball.vx * sub;
            ball.y += ball.vy * sub;

            // Walls + ceiling.
            if ball.x < SIDE + BALL_R {
                ball.x = SIDE + BALL_R;
                ball.vx = ball.vx.abs();
            } else if ball.x > w - SIDE - BALL_R {
                ball.x = w - SIDE - BALL_R;
                ball.vx = -ball.vx.abs();
            }
            if ball.y < BALL_R {
                ball.y = BALL_R;
                ball.vy = ball.vy.abs();
            }

            // Paddle.
            let py = self.paddle_y;
            let pw = self.paddle_w();
            if ball.vy > 0.0
                && ball.y + BALL_R >= py - PADDLE_H / 2.0
                && ball.y - BALL_R <= py + PADDLE_H / 2.0
                && (ball.x - self.paddle_x).abs() <= pw / 2.0 + BALL_R
            {
                let hit = ((ball.x - self.paddle_x) / (pw / 2.0)).clamp(-1.0, 1.0);
                let s = self.speed();
                let ang = hit * 1.05;
                ball.vx = s * ang.sin();
                ball.vy = -s * ang.cos();
                ball.y = py - PADDLE_H / 2.0 - BALL_R - 0.5;
            }

            // Bricks.
            self.hit_bricks(ball, w);

            // Lost below the field.
            if ball.y - BALL_R > h {
                return false;
            }
        }
        true
    }

    fn hit_bricks(&mut self, ball: &mut Ball, w: f64) {
        let bw = (w - 2.0 * SIDE - (COLS as f64 - 1.0) * BRICK_GAP) / COLS as f64;
        let smash = self.smash_t > 0.0;
        for row in 0..ROWS {
            for col in 0..COLS {
                let idx = row * COLS + col;
                if self.bricks[idx] == 0 {
                    continue;
                }
                let rx = SIDE + col as f64 * (bw + BRICK_GAP);
                let ry = BRICK_TOP + row as f64 * (BRICK_H + BRICK_GAP);
                let cx = ball.x.clamp(rx, rx + bw);
                let cy = ball.y.clamp(ry, ry + BRICK_H);
                let dx = ball.x - cx;
                let dy = ball.y - cy;
                if dx * dx + dy * dy > BALL_R * BALL_R {
                    continue;
                }
                if !smash {
                    // Reflect on the axis of least penetration.
                    let pen_x = BALL_R - dx.abs();
                    let pen_y = BALL_R - dy.abs();
                    if pen_x < pen_y {
                        ball.vx = if ball.x < rx + bw / 2.0 {
                            -ball.vx.abs()
                        } else {
                            ball.vx.abs()
                        };
                    } else {
                        ball.vy = if ball.y < ry + BRICK_H / 2.0 {
                            -ball.vy.abs()
                        } else {
                            ball.vy.abs()
                        };
                    }
                    self.bricks[idx] -= 1;
                } else {
                    self.bricks[idx] = 0; // smash straight through
                }
                if self.bricks[idx] == 0 {
                    self.break_brick(idx, rx + bw / 2.0, ry + BRICK_H / 2.0, row);
                } else {
                    self.spawn_burst(ball.x, ball.y, Color::WHITE, 3);
                }
                if !smash {
                    return; // one brick per substep unless smashing
                }
            }
        }
    }

    fn break_brick(&mut self, idx: usize, cx: f64, cy: f64, row: usize) {
        self.score += row_points(row) * 10;
        if self.score > self.best {
            self.best = self.score;
        }
        self.spawn_burst(cx, cy, row_color(row), 8);
        // Pre-loaded power-up, or a small random drop.
        if let Some(kind) = self.powered[idx].take() {
            self.drops.push(Drop { x: cx, y: cy, kind });
        } else if self.rng.unit() < PU_DROP_CHANCE {
            let kind = Power::from_index(self.rng.next());
            self.drops.push(Drop { x: cx, y: cy, kind });
        }
        if self.bricks.iter().all(|&b| b == 0) {
            // Deferred: `step` advances the level once the ball loop is done (see the field
            // note on `level_cleared`).
            self.level_cleared = true;
        }
    }

    fn draw(&self, d: &mut Draw, sz: Size) {
        let (w, h) = (sz.width, sz.height);
        d.fill(
            Shape::Rect(Rect::new(0.0, 0.0, w, h)),
            Color::hex(0x0B_0B_1A),
        );

        // Bricks (a power-up brick shows a subtle inner dot).
        let bw = (w - 2.0 * SIDE - (COLS as f64 - 1.0) * BRICK_GAP) / COLS as f64;
        for row in 0..ROWS {
            for col in 0..COLS {
                let idx = row * COLS + col;
                let hp = self.bricks[idx];
                if hp == 0 {
                    continue;
                }
                let rx = SIDE + col as f64 * (bw + BRICK_GAP);
                let ry = BRICK_TOP + row as f64 * (BRICK_H + BRICK_GAP);
                let mut c = row_color(row);
                if hp >= 2 {
                    c = Color::hsl(8.0 + row as f64 * 40.0, 0.35, 0.72);
                }
                d.fill(Shape::RoundedRect(Rect::new(rx, ry, bw, BRICK_H), 4.0), c);
                if let Some(k) = self.powered[idx] {
                    d.fill(
                        Shape::Ellipse(Rect::new(
                            rx + bw / 2.0 - 3.0,
                            ry + BRICK_H / 2.0 - 3.0,
                            6.0,
                            6.0,
                        )),
                        Color::rgba(1.0, 1.0, 1.0, 0.85),
                    );
                    let _ = k;
                }
            }
        }

        // Particles.
        for p in &self.particles {
            let a = (p.life / p.max).clamp(0.0, 1.0);
            let col = Color::rgba(p.color.r, p.color.g, p.color.b, a);
            let s = 3.0 * a + 1.0;
            d.fill(
                Shape::Ellipse(Rect::new(p.x - s, p.y - s, 2.0 * s, 2.0 * s)),
                col,
            );
        }

        // Falling power-ups.
        for dr in &self.drops {
            d.fill(
                Shape::RoundedRect(
                    Rect::new(dr.x - PU_R, dr.y - PU_R * 0.7, PU_R * 2.0, PU_R * 1.4),
                    6.0,
                ),
                dr.kind.color(),
            );
            d.text(
                dr.kind.glyph(),
                Point::new(dr.x, dr.y),
                TextStyle {
                    size: 15.0,
                    color: Color::hex(0x10_10_18),
                    anchor: TextAnchor::Centered,
                },
            );
        }

        // Paddle (cyan while wide).
        let pw = self.paddle_w();
        let paddle_col = if self.wide_t > 0.0 {
            Color::hex(0x22_D3_EE)
        } else {
            Color::hex(0xE8_ED_F5)
        };
        d.fill(
            Shape::RoundedRect(
                Rect::new(
                    self.paddle_x - pw / 2.0,
                    self.paddle_y - PADDLE_H / 2.0,
                    pw,
                    PADDLE_H,
                ),
                7.0,
            ),
            paddle_col,
        );

        // Balls (orange while smashing). The resting ball is drawn from the paddle position.
        let ball_col = if self.smash_t > 0.0 {
            Color::hex(0xF5_9E_0B)
        } else {
            Color::WHITE
        };
        let draw_ball = |d: &mut Draw, x: f64, y: f64| {
            d.fill(
                Shape::Ellipse(Rect::new(
                    x - BALL_R,
                    y - BALL_R,
                    2.0 * BALL_R,
                    2.0 * BALL_R,
                )),
                ball_col,
            );
        };
        if self.launched {
            for b in &self.balls {
                draw_ball(d, b.x, b.y);
            }
        } else {
            let (x, y) = self.resting_ball_pos();
            draw_ball(d, x, y);
        }

        // HUD. The leading gutter keeps the score clear of the cover's close button.
        let hud = TextStyle {
            size: 15.0,
            color: Color::rgba(1.0, 1.0, 1.0, 0.85),
            anchor: TextAnchor::Leading,
        };
        d.text(
            &tr("bk_score").arg("n", self.score).format(),
            Point::new(SIDE + CLOSE_GUTTER, 14.0),
            hud,
        );
        d.text(
            &tr("bk_level").arg("n", self.level as i64).format(),
            Point::new(w / 2.0 - 20.0, 14.0),
            hud,
        );
        for i in 0..self.lives.max(0) {
            d.fill(
                Shape::Ellipse(Rect::new(
                    w - SIDE - 16.0 - i as f64 * 18.0,
                    16.0,
                    10.0,
                    10.0,
                )),
                Color::hex(0xFF_5B_5B),
            );
        }
        // Active-effect badges.
        let mut bx = SIDE + CLOSE_GUTTER;
        let badge = |d: &mut Draw, x: &mut f64, text: &str, color: Color| {
            let wd = 16.0 + text.len() as f64 * 8.5;
            d.fill(
                Shape::RoundedRect(Rect::new(*x, 34.0, wd, 20.0), 6.0),
                color,
            );
            d.text(
                text,
                Point::new(*x + wd / 2.0, 44.0),
                TextStyle {
                    size: 12.0,
                    color: Color::hex(0x10_10_18),
                    anchor: TextAnchor::Centered,
                },
            );
            *x += wd + 6.0;
        };
        if self.wide_t > 0.0 {
            badge(d, &mut bx, &tr("bk_wide").format(), Power::Wide.color());
        }
        if self.slow_t > 0.0 {
            badge(d, &mut bx, &tr("bk_slow").format(), Power::Slow.color());
        }
        if self.smash_t > 0.0 {
            badge(d, &mut bx, &tr("bk_smash").format(), Power::Smash.color());
        }

        // Overlays.
        if !self.launched && !self.game_over {
            self.center_text(d, w, h, &tr("bk_tap_to_launch").format(), 22.0, 0.9);
        }
        if self.game_over {
            d.fill(
                Shape::Rect(Rect::new(0.0, 0.0, w, h)),
                Color::rgba(0.0, 0.0, 0.05, 0.55),
            );
            self.center_text(d, w, h - 30.0, &tr("bk_game_over").format(), 34.0, 1.0);
            self.center_text(d, w, h + 24.0, &tr("bk_play_again").format(), 18.0, 0.85);
        }
    }

    fn center_text(&self, d: &mut Draw, w: f64, h: f64, s: &str, size: f64, alpha: f64) {
        d.text(
            s,
            Point::new(w / 2.0, h / 2.0),
            TextStyle {
                size,
                color: Color::rgba(1.0, 1.0, 1.0, alpha),
                anchor: TextAnchor::Centered,
            },
        );
    }
}

/// The home-grid tile preview: the REAL gameplay renderer (`Game::draw`) over a curated
/// mid-game state, scaled from a 240×240 virtual field into the tile.
pub fn breakout_preview() -> AnyPiece {
    canvas(|d, sz| {
        if sz.width < 4.0 || sz.height < 4.0 {
            return;
        }
        let field = Size::new(280.0, 280.0);
        let mut g = Game::new();
        g.rng = Rng(0x5EED_0001);
        g.field = field;
        g.paddle_x = field.width * 0.44;
        g.paddle_y = g.paddle_rest_y();
        // Clear the two brick rows nearest the paddle (a square field has no room for them)
        // plus a bitten-out notch, so the tile reads as a game in progress.
        for col in 0..COLS {
            g.bricks[4 * COLS + col] = 0;
            g.bricks[5 * COLS + col] = 0;
        }
        for &(row, col) in &[(3usize, 2usize), (3, 3), (2, 3), (3, 4)] {
            g.bricks[row * COLS + col] = 0;
        }
        g.powered = vec![None; ROWS * COLS];
        g.powered[2 * COLS + 5] = Some(Power::Multi);
        g.score = 80;
        g.launched = true;
        g.balls.push(Ball {
            x: field.width * 0.58,
            y: field.height * 0.72,
            vx: 0.0,
            vy: 0.0,
        });
        d.transformed(
            Affine::scale(sz.width / field.width, sz.height / field.height),
            |d| g.draw(d, field),
        );
    })
    .any()
}

/// The Breakout screen.
pub fn breakout_page() -> AnyPiece {
    let game = Rc::new(RefCell::new(Game::new()));
    if let Some(s) = gamekit::restore::<SaveState>(SAVE_KEY) {
        game.borrow_mut().apply_save(s);
    }
    gamekit::autosave(SAVE_KEY, {
        let game = game.clone();
        move || game.borrow().save_state()
    });
    let repaint = Trigger::new();

    let cv = {
        let game = game.clone();
        canvas(move |d, sz| {
            repaint.track();
            {
                let mut g = game.borrow_mut();
                let first = g.field.width < 10.0;
                g.field = sz;
                if first && sz.width > 10.0 {
                    g.paddle_x = sz.width / 2.0;
                    g.paddle_y = g.paddle_rest_y();
                    g.rest_ball();
                }
            }
            game.borrow().draw(d, sz);
        })
    }
    .on_drag({
        let game = game.clone();
        move |dr| {
            let mut g = game.borrow_mut();
            g.set_paddle(dr.location.x, dr.location.y);
            if matches!(dr.phase, DragPhase::Began) {
                g.launch();
            }
            drop(g);
            repaint.notify();
        }
    })
    .on_tap({
        let game = game.clone();
        move || {
            let mut g = game.borrow_mut();
            if g.game_over {
                g.restart();
            } else {
                g.launch();
            }
            drop(g);
            repaint.notify();
        }
    })
    .id("bk-canvas")
    .grow();

    let clock = frame_clock({
        let game = game.clone();
        move |dt| {
            game.borrow_mut().step(dt.as_secs_f64());
            repaint.notify();
        }
    });

    zstack((cv, clock)).any()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn game_400x700() -> Game {
        let mut g = Game::new();
        g.field = Size::new(400.0, 700.0);
        g.paddle_x = 200.0;
        g.paddle_y = g.paddle_rest_y();
        g
    }

    #[test]
    fn paddle_never_passes_through_ball() {
        let mut g = game_400x700();
        g.launched = true;
        // A ball hovering just above the paddle, within its horizontal span.
        g.balls = vec![Ball {
            x: 200.0,
            y: g.paddle_y - 30.0,
            vx: 0.0,
            vy: 0.0,
        }];
        // Lunge the paddle UP fast, well above the ball (finger arg = target + lift).
        let target_py = 480.0;
        g.set_paddle(200.0, target_py + PADDLE_LIFT);
        let ball = g.balls[0];
        let paddle_top = g.paddle_y - PADDLE_H / 2.0;
        // The ball must be carried on top of the paddle, never left below its top edge.
        assert!(
            ball.y + BALL_R <= paddle_top + 0.6,
            "ball bottom {} passed through paddle top {}",
            ball.y + BALL_R,
            paddle_top
        );
        assert!(
            ball.vy < 0.0,
            "ball should be knocked upward, vy = {}",
            ball.vy
        );
    }

    #[test]
    fn multi_ball_triples_and_caps() {
        let mut g = game_400x700();
        g.launched = true;
        g.balls = vec![Ball {
            x: 200.0,
            y: 300.0,
            vx: 0.0,
            vy: -300.0,
        }];
        g.catch(Power::Multi);
        assert_eq!(g.balls.len(), 3, "one ball splits into three");
        // Splitting again respects MAX_BALLS.
        g.catch(Power::Multi);
        assert!(g.balls.len() <= MAX_BALLS);
    }

    #[test]
    fn extra_life_and_wide_and_slow() {
        let mut g = game_400x700();
        g.lives = 3;
        g.catch(Power::ExtraLife);
        assert_eq!(g.lives, 4);
        assert!(g.paddle_w() == PADDLE_W);
        g.catch(Power::Wide);
        assert!(g.paddle_w() == PADDLE_WIDE_W);
        g.catch(Power::Slow);
        assert!(g.slow_t > 0.0);
    }

    #[test]
    fn completing_a_level_mid_step_does_not_panic() {
        let mut g = game_400x700();
        g.launched = true;
        // One brick left, dead ahead of a ball moving straight up into it — plus a second
        // ball, so the loop keeps iterating after the level-clearing hit.
        g.bricks = vec![0; ROWS * COLS];
        g.bricks[5 * COLS + 3] = 1;
        let bw = (g.field.width - 2.0 * SIDE - (COLS as f64 - 1.0) * BRICK_GAP) / COLS as f64;
        let bx = SIDE + 3.0 * (bw + BRICK_GAP) + bw / 2.0;
        let by = BRICK_TOP + 5.0 * (BRICK_H + BRICK_GAP) + BRICK_H + BALL_R + 2.0;
        g.balls = vec![
            Ball {
                x: bx,
                y: by,
                vx: 0.0,
                vy: -300.0,
            },
            Ball {
                x: 40.0,
                y: 400.0,
                vx: 50.0,
                vy: 50.0,
            },
        ];
        let lives = g.lives;
        g.step(0.05); // must not panic (the old code cleared `balls` mid-iteration)
        assert_eq!(g.level, 2, "level advanced");
        assert!(!g.launched && g.balls.is_empty(), "ball parked for level 2");
        assert!(
            g.bricks.iter().any(|&b| b > 0),
            "next level's bricks are laid"
        );
        assert_eq!(g.lives, lives, "clearing a level costs no life");
    }

    #[test]
    fn smash_ball_passes_through_bricks() {
        let mut g = game_400x700();
        g.launched = true;
        g.smash_t = SMASH_DUR;
        // A ball moving up through the brick field should clear multiple bricks in one pass.
        let before: u32 = g.bricks.iter().map(|&b| b as u32).sum();
        let mut ball = Ball {
            x: 100.0,
            y: BRICK_TOP + 10.0,
            vx: 0.0,
            vy: -400.0,
        };
        // Manually sweep the ball across the rows it overlaps.
        for _ in 0..ROWS {
            g.hit_bricks(&mut ball, g.field.width);
            ball.y += BRICK_H + BRICK_GAP;
        }
        let after: u32 = g.bricks.iter().map(|&b| b as u32).sum();
        assert!(after < before, "smash should have cleared bricks");
    }
}
