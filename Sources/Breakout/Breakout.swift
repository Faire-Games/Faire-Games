// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import Observation
import SkipKit
import FaireGamesModel

public struct BreakoutContainerView: View {
    @State private var settings = BreakoutSettings()
    @State private var showInstructions: Bool = false
    private let instructionsConfig = GameInstructionsConfig(
        key: "Breakout.instructions",
        bundle: .module,
        firstLaunchKey: "instructionsShown_Breakout",
        title: "Breakout"
    )

    public init() { }

    public var body: some View {
        BreakoutGameView(showInstructions: $showInstructions)
            .navigationTitle("")
            #if !os(macOS)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            #if SKIP
            .ignoresSafeArea(.container, edges: .top)
            #else
            .persistentSystemOverlays(.hidden) // hide the bottom home swipe bar
            #endif
            .colorScheme(.dark)
            #endif
            .environment(settings)
            .sheet(isPresented: $showInstructions) {
                GameInstructionsView(config: instructionsConfig)
            }
            .onAppear {
                if !instructionsConfig.hasShownToUser() {
                    instructionsConfig.markShownToUser()
                    showInstructions = true
                }
            }
    }
}

public func resetBreakoutHighScore() {
    UserDefaults.standard.set(0, forKey: "breakout_highscore")
}

// MARK: - Constants

private let paddleHeight: Double = 14.0
private let paddleBottomFraction: Double = 0.25 // paddle sits 1/4 from bottom
private let ballRadius: Double = 7.0
private let brickRows: Int = 8
private let brickCols: Int = 10
private let brickHeight: Double = 16.0
private let brickSpacing: Double = 2.0
private let brickTopMargin: Double = 80.0
private let initialBallSpeed: Double = 320.0

private let basePaddleWidth: Double = 72.0
private let widePaddleWidth: Double = 112.0
private let paddleWidthLerpRate: Double = 6.0

// Touch tracking: the paddle is positioned absolutely under the touch point
// rather than dragged relative to where the gesture began. It rides this far
// ABOVE the fingertip so the player can always see it, and eases toward the
// touch position at paddleFollowRate so lifting and re-tapping somewhere new
// glides the paddle across instead of teleporting it.
//
// paddleFollowRate is an exponential easing constant in units of 1/second (see
// stepPaddle). The glide reaches ~95% of the way in roughly 3/rate seconds —
// here ~0.14s — INDEPENDENT of frame rate, so it stays a smooth multi-frame
// slide whether the game ticks at 60fps (iOS) or a lower, choppier rate
// (Android). Higher = snappier/tighter tracking; lower = a longer, softer glide.
private let paddleTouchYOffset: Double = 72.0
private let paddleFollowRate: Double = 22.0

// Power-ups
private let powerUpDropChance: Double = 0.20
private let powerUpFallSpeed: Double = 130.0
private let powerUpWidth: Double = 30.0
private let powerUpHeight: Double = 16.0
private let powerUpCatchScore: Int = 50
private let widePaddleDuration: Double = 14.0
private let slowBallDuration: Double = 13.0
private let slowBallFactor: Double = 0.62
private let smashBallDuration: Double = 8.0
private let maxLives: Int = 5

// Combo
private let comboCap: Int = 4
private let comboMinDisplay: Int = 2
private let comboDecayWindow: Double = 1.4   // seconds of inactivity to reset

// Particles
private let particleGravity: Double = 240.0
private let particleLifeMin: Double = 0.45
private let particleLifeMax: Double = 0.85

// Score popups
private let popupLife: Double = 0.85
private let popupRiseSpeed: Double = 60.0

// Ball trail
private let ballTrailMax: Int = 7

// Row colors — classic rainbow from top to bottom
private let rowColors: [(Double, Double, Double)] = [
    (0.90, 0.20, 0.20), // red
    (0.95, 0.40, 0.15), // orange-red
    (0.95, 0.60, 0.10), // orange
    (0.95, 0.80, 0.15), // yellow
    (0.40, 0.80, 0.25), // green
    (0.20, 0.70, 0.55), // teal
    (0.30, 0.50, 0.90), // blue
    (0.55, 0.35, 0.85), // purple
]

// Points per row (top rows are worth more)
private let rowPoints: [Int] = [7, 7, 5, 5, 3, 3, 1, 1]

// MARK: - Power-up Kind

enum PowerUpKind: Int, Codable, CaseIterable {
    case widePaddle = 0
    case multiBall = 1
    case slowBall = 2
    case extraLife = 3
    case smashBall = 4

    var letter: String {
        switch self {
        case .widePaddle: return "W"
        case .multiBall: return "M"
        case .slowBall: return "S"
        case .extraLife: return "+1"
        case .smashBall: return "★"
        }
    }

    var color: (Double, Double, Double) {
        switch self {
        case .widePaddle: return (0.30, 0.72, 0.95)  // cyan
        case .multiBall:  return (0.95, 0.40, 0.85)  // magenta
        case .slowBall:   return (0.55, 0.55, 1.00)  // sky-blue
        case .extraLife:  return (0.42, 0.88, 0.45)  // green
        case .smashBall:  return (1.00, 0.55, 0.20)  // fiery orange
        }
    }

    /// Effect duration in seconds. Zero means instantaneous (no timer indicator).
    var duration: Double {
        switch self {
        case .widePaddle: return widePaddleDuration
        case .slowBall:   return slowBallDuration
        case .smashBall:  return smashBallDuration
        case .multiBall, .extraLife: return 0.0
        }
    }
}

/// A randomly-picked power-up kind. Implemented as a free function (rather than a
/// `static` factory) so it transpiles cleanly through Skip Lite.
private func randomPowerUpKind() -> PowerUpKind {
    let all = PowerUpKind.allCases
    let i = Int.random(in: 0..<all.count)
    return all[i]
}

// MARK: - Ball, Particle, Power-up, Popup

/// One ball — primary and any extras from multi-ball share this type. Reference
/// semantics keep mutation cheap when the array changes during a frame.
final class Ball {
    var x: Double
    var y: Double
    var dx: Double
    var dy: Double

    init(x: Double, y: Double, dx: Double, dy: Double) {
        self.x = x
        self.y = y
        self.dx = dx
        self.dy = dy
    }
}

final class FallingPowerUp {
    var x: Double
    var y: Double
    let kind: PowerUpKind

    init(x: Double, y: Double, kind: PowerUpKind) {
        self.x = x
        self.y = y
        self.kind = kind
    }
}

final class Particle {
    var x: Double
    var y: Double
    var dx: Double
    var dy: Double
    /// Remaining lifetime in seconds.
    var life: Double
    let maxLife: Double
    let r: Double
    let g: Double
    let b: Double
    let size: Double

    init(x: Double, y: Double, dx: Double, dy: Double,
         life: Double, color: (Double, Double, Double), size: Double) {
        self.x = x
        self.y = y
        self.dx = dx
        self.dy = dy
        self.life = life
        self.maxLife = life
        self.r = color.0
        self.g = color.1
        self.b = color.2
        self.size = size
    }
}

final class ScorePopup {
    var x: Double
    var y: Double
    var life: Double
    let text: String
    let r: Double
    let g: Double
    let b: Double

    init(x: Double, y: Double, text: String, color: (Double, Double, Double)) {
        self.x = x
        self.y = y
        self.text = text
        self.life = popupLife
        self.r = color.0
        self.g = color.1
        self.b = color.2
    }
}

// MARK: - Brick Model

final class BrickData {
    var hp: Int
    let maxHp: Int
    let row: Int
    let col: Int
    /// -1 = no power-up; otherwise PowerUpKind.rawValue. Used as a sentinel rather
    /// than `Optional<PowerUpKind>` because plain Int transpiles more predictably.
    let powerUpKindRaw: Int

    init(row: Int, col: Int, hp: Int, powerUpKindRaw: Int) {
        self.row = row
        self.col = col
        self.hp = hp
        self.maxHp = hp
        self.powerUpKindRaw = powerUpKindRaw
    }

    var alive: Bool { hp > 0 }
}

// MARK: - Saved State

struct BreakoutSavedState: Codable {
    var paddleX: Double
    var ballX: Double
    var ballY: Double
    var ballDX: Double
    var ballDY: Double
    var brickAlive: [Bool]
    var score: Int
    var lives: Int
    var level: Int
    var isGameOver: Bool
    var isLevelComplete: Bool
    var isLaunched: Bool
}

// MARK: - Game Model

@Observable
final class BreakoutModel {
    // Field
    var fieldWidth: Double = 400.0
    var fieldHeight: Double = 700.0

    // Paddle
    var paddleX: Double = 200.0 // center
    var paddleY: Double = 525.0 // baseline; reset in setup() once fieldHeight is known
    var paddleWidth: Double = basePaddleWidth

    /// Paddle position captured at the start of the previous tick. Used by
    /// the swept paddle-ball collision check to detect fast paddle motion
    /// (a quick drag through the ball would otherwise let the ball tunnel
    /// straight through). Also drives the "fast paddle adds ball speed"
    /// behaviour on impact.
    var prevPaddleX: Double = 200.0
    var prevPaddleY: Double = 525.0

    /// Absolute destination for the paddle, set from the touch point. The paddle
    /// eases toward this each tick (see `stepPaddle`) instead of snapping, so a
    /// fresh tap somewhere new glides the paddle across rather than teleporting
    /// it. Kept equal to the paddle's resting position until the first touch.
    var paddleTargetX: Double = 200.0
    var paddleTargetY: Double = 525.0

    /// Default resting Y for the paddle: 1/4 of the way up from the bottom,
    /// adjusted so the paddle's center (not edge) sits at that line.
    var paddleYBaseline: Double {
        fieldHeight * (1.0 - paddleBottomFraction) - paddleHeight / 2.0
    }

    /// Upper bound of the paddle's vertical travel: half-way down from the
    /// top of the playfield. A vertical drag can lift the paddle this far
    /// from its baseline but no higher — anything above this crowds the
    /// bricks and makes the game trivial.
    var paddleYMin: Double {
        fieldHeight / 2.0
    }

    /// Lower bound of the paddle's vertical travel: the paddle's bottom edge
    /// rests against the bottom of the playfield with a small visual margin,
    /// so the player can push it all the way down to make the death zone as
    /// small as possible.
    var paddleYMax: Double {
        fieldHeight - paddleHeight / 2.0 - 2.0
    }

    // Primary ball (scalar state kept for save compatibility + simple observation)
    var ballX: Double = 200.0
    var ballY: Double = 500.0
    var ballDX: Double = 0.0
    var ballDY: Double = 0.0

    /// Extra balls spawned by the multi-ball power-up. Reduced in-place as they
    /// fall off the bottom; if the primary ball is lost, one extra is promoted.
    var extraBalls: [Ball] = []

    /// Recent positions of the primary ball, drawn as a fading trail.
    var ballTrail: [(Double, Double)] = []

    // Paddle hit feedback: -1 = no hit this frame, 0..1 = deflection amount
    // (0 = mirror reflection, 1 = maximum angle change)
    var lastPaddleDeflection: Double = -1.0

    // Bricks
    var bricks: [[BrickData]] = []

    // Power-ups in flight + active effect timers
    var fallingPowerUps: [FallingPowerUp] = []
    var widePaddleTimer: Double = 0.0
    var slowBallTimer: Double = 0.0
    var smashBallTimer: Double = 0.0

    // Combo
    var combo: Int = 0
    var comboDecay: Double = 0.0
    var lastComboFlash: Double = 0.0

    // Particles & popups
    var particles: [Particle] = []
    var scorePopups: [ScorePopup] = []

    // Side-wall hit prediction (for the guide indicator)
    /// -1 = none, 0 = left wall, 1 = right wall.
    var predictedSide: Int = -1
    var predictedY: Double = 0.0

    // State
    var score: Int = 0
    var highScore: Int = UserDefaults.standard.integer(forKey: "breakout_highscore")
    var lives: Int = 3
    var level: Int = 1
    var isGameOver: Bool = false
    var isLevelComplete: Bool = false
    var isLaunched: Bool = false // ball is sitting on paddle until launched

    // Layout cache
    var brickWidth: Double = 36.0
    var brickAreaLeft: Double = 4.0

    private var ballSpeed: Double = initialBallSpeed

    func setup(width: Double, height: Double) {
        guard fieldWidth != width || fieldHeight != height else { return }
        fieldWidth = width
        fieldHeight = height
        paddleX = width / 2.0
        paddleY = height * (1.0 - paddleBottomFraction) - paddleHeight / 2.0
        prevPaddleX = paddleX
        prevPaddleY = paddleY
        paddleTargetX = paddleX
        paddleTargetY = paddleY

        // Keep a pre-launch ball glued to the paddle's new position. setup() runs
        // on every GeometryReader size change, and a later layout pass can hand us a
        // different (often shorter) height once safe-area / nav-bar insets resolve.
        // That moves the paddle; if the ball doesn't follow it can end up stranded
        // BELOW the paddle and is lost the instant the turn starts. (A launched ball
        // is mid-flight and must keep its own trajectory.)
        if !isLaunched {
            ballX = paddleX
            ballY = paddleY - paddleHeight / 2.0 - ballRadius - 2.0
            ballDX = 0.0
            ballDY = 0.0
            ballTrail.removeAll()
        }

        // Calculate brick layout
        let totalSpacing = brickSpacing * Double(brickCols + 1)
        brickWidth = (width - totalSpacing) / Double(brickCols)
        brickAreaLeft = brickSpacing
    }

    func newGame() {
        score = 0
        lives = 3
        level = 1
        isGameOver = false
        isLevelComplete = false
        ballSpeed = initialBallSpeed
        clearTransient()
        buildLevel()
        resetBall()
    }

    func startLevel(lvl: Int) {
        level = lvl
        isLevelComplete = false
        // Speed increases each level
        ballSpeed = initialBallSpeed + Double(level - 1) * 25.0
        clearTransient()
        buildLevel()
        resetBall()
    }

    /// Clears in-flight state that shouldn't survive a new game or level transition.
    private func clearTransient() {
        extraBalls.removeAll()
        ballTrail.removeAll()
        fallingPowerUps.removeAll()
        particles.removeAll()
        scorePopups.removeAll()
        widePaddleTimer = 0.0
        slowBallTimer = 0.0
        smashBallTimer = 0.0
        combo = 0
        comboDecay = 0.0
        paddleWidth = basePaddleWidth
        predictedSide = -1
    }

    private func brickHP(row: Int, level lvl: Int) -> Int {
        // Higher levels sprinkle in tougher bricks at the top.
        if lvl >= 4 && row == 0 { return 3 }
        if lvl >= 3 && row < 2 { return 2 }
        if lvl >= 2 && row == 0 { return 2 }
        return 1
    }

    private func buildLevel() {
        bricks = []
        // Decide which bricks carry power-ups before construction so each level has
        // a predictable handful (2–4) rather than the chance-of-drop being purely
        // per-hit. We still randomise *which* bricks and *which* kinds.
        let totalCells = brickRows * brickCols
        let numPowerUps = 2 + Int.random(in: 0...2)
        var powerUpCells: Set<Int> = []
        while powerUpCells.count < numPowerUps {
            powerUpCells.insert(Int.random(in: 0..<totalCells))
        }
        for r in 0..<brickRows {
            var row: [BrickData] = []
            for c in 0..<brickCols {
                let flatIndex = r * brickCols + c
                let puRaw: Int
                if powerUpCells.contains(flatIndex) {
                    puRaw = randomPowerUpKind().rawValue
                } else {
                    puRaw = -1
                }
                row.append(BrickData(row: r, col: c,
                                     hp: brickHP(row: r, level: level),
                                     powerUpKindRaw: puRaw))
            }
            bricks.append(row)
        }
    }

    func resetBall() {
        isLaunched = false
        // Drop the paddle back to its baseline so the ball can re-sit on it
        // without ending up mid-air after a vertical drag before launch.
        paddleY = paddleYBaseline
        prevPaddleX = paddleX
        prevPaddleY = paddleY
        // Re-aim the touch target at the reset position so the paddle doesn't
        // immediately glide away from the ball it's about to launch.
        paddleTargetX = paddleX
        paddleTargetY = paddleY
        ballX = paddleX
        ballY = paddleY - paddleHeight / 2.0 - ballRadius - 2.0
        ballDX = 0.0
        ballDY = 0.0
        ballTrail.removeAll()
        combo = 0
        comboDecay = 0.0
        // Don't clear extras here — they're cleared on lose-life / new game.
    }

    func launch() {
        guard !isLaunched else { return }
        isLaunched = true
        // Slight random angle so it's not always straight up
        let angle = Double.random(in: -0.4...0.4)
        ballDX = ballSpeed * sin(angle)
        ballDY = -ballSpeed * cos(angle)
    }

    // MARK: - Update loop

    func update(dt: Double) {
        guard isLaunched && !isGameOver && !isLevelComplete else { return }

        lastPaddleDeflection = -1.0

        // Power-up effect timers
        if widePaddleTimer > 0.0 {
            widePaddleTimer -= dt
            if widePaddleTimer < 0.0 { widePaddleTimer = 0.0 }
        }
        if slowBallTimer > 0.0 {
            slowBallTimer -= dt
            if slowBallTimer < 0.0 { slowBallTimer = 0.0 }
        }
        if smashBallTimer > 0.0 {
            smashBallTimer -= dt
            if smashBallTimer < 0.0 { smashBallTimer = 0.0 }
        }

        // Smoothly lerp paddle width toward target.
        let targetWidth = widePaddleTimer > 0.0 ? widePaddleWidth : basePaddleWidth
        let lerpStep = min(dt * paddleWidthLerpRate, 1.0)
        paddleWidth = paddleWidth + (targetWidth - paddleWidth) * lerpStep

        // Apply slow-ball as a position-update scale so we don't lose precision in
        // the stored velocity (and the effect smoothly ends without a speed jump).
        let speedScale = slowBallTimer > 0.0 ? slowBallFactor : 1.0

        // ---- Primary ball physics ----
        let primaryLost = stepPrimaryBall(dt: dt, speedScale: speedScale)

        // ---- Extra balls physics ----
        var i = 0
        while i < extraBalls.count {
            let b = extraBalls[i]
            let lost = stepBall(ball: b, dt: dt, speedScale: speedScale)
            if lost {
                extraBalls.remove(at: i)
            } else {
                i += 1
            }
        }

        // Trail (primary ball only)
        ballTrail.append((ballX, ballY))
        while ballTrail.count > ballTrailMax {
            ballTrail.removeFirst()
        }

        // Predicted side-wall hit (primary ball only)
        updatePrediction()

        // Combo decay timer — resets combo if no brick was hit for a while.
        if combo > 0 {
            comboDecay -= dt
            if comboDecay <= 0.0 { combo = 0 }
        }

        // Falling power-ups
        var pi = 0
        while pi < fallingPowerUps.count {
            let p = fallingPowerUps[pi]
            p.y += powerUpFallSpeed * dt
            // Off-screen
            if p.y > fieldHeight + powerUpHeight {
                fallingPowerUps.remove(at: pi)
                continue
            }
            // Paddle catch
            let paddleTop = paddleY - paddleHeight / 2.0
            let paddleLeft = paddleX - paddleWidth / 2.0
            let paddleRight = paddleX + paddleWidth / 2.0
            let halfPU = powerUpWidth / 2.0
            if p.y + powerUpHeight / 2.0 >= paddleTop &&
               p.y - powerUpHeight / 2.0 <= paddleTop + paddleHeight &&
               p.x + halfPU >= paddleLeft &&
               p.x - halfPU <= paddleRight {
                applyPowerUp(kind: p.kind, at: p.x, y: p.y)
                fallingPowerUps.remove(at: pi)
                continue
            }
            pi += 1
        }

        // Particles physics + culling
        var qi = 0
        while qi < particles.count {
            let q = particles[qi]
            q.dy += particleGravity * dt
            q.x += q.dx * dt
            q.y += q.dy * dt
            q.life -= dt
            if q.life <= 0.0 || q.y > fieldHeight + 30.0 {
                particles.remove(at: qi)
            } else {
                qi += 1
            }
        }

        // Score popups
        var si = 0
        while si < scorePopups.count {
            let s = scorePopups[si]
            s.y -= popupRiseSpeed * dt
            s.life -= dt
            if s.life <= 0.0 {
                scorePopups.remove(at: si)
            } else {
                si += 1
            }
        }

        // Handle primary loss after extras have stepped — promotion needs both lists consistent.
        if primaryLost {
            if !extraBalls.isEmpty {
                // Promote the most central extra so the demotion feels natural.
                let centerX = fieldWidth / 2.0
                var best = 0
                var bestDist = abs(extraBalls[0].x - centerX)
                for k in 1..<extraBalls.count {
                    let d = abs(extraBalls[k].x - centerX)
                    if d < bestDist { best = k; bestDist = d }
                }
                let promoted = extraBalls.remove(at: best)
                ballX = promoted.x
                ballY = promoted.y
                ballDX = promoted.dx
                ballDY = promoted.dy
                ballTrail.removeAll()
            } else {
                lives -= 1
                combo = 0
                widePaddleTimer = 0.0
                slowBallTimer = 0.0
                smashBallTimer = 0.0
                paddleWidth = basePaddleWidth
                fallingPowerUps.removeAll()
                if lives <= 0 {
                    isGameOver = true
                    saveHighScore()
                } else {
                    resetBall()
                }
                return
            }
        }

        // Check level complete
        var anyAlive = false
        for row in bricks {
            for brick in row {
                if brick.alive {
                    anyAlive = true
                    break
                }
            }
            if anyAlive { break }
        }
        if !anyAlive {
            isLevelComplete = true
            saveHighScore()
            clearTransient()
        }
        // NOTE: prevPaddleX/Y are snapshotted in stepPaddle() at the start of each
        // tick (before the paddle eases toward its target), so the swept paddle/ball
        // collision above already sees this frame's paddle motion — nothing to do here.
    }

    /// Ease the paddle toward its touch-driven target. Called once per tick, before
    /// `update`, so all paddle motion happens inside the simulation step. The
    /// pre-move position is captured into `prevPaddle*` for the swept paddle/ball
    /// collision, and the eased motion (rather than a teleport) keeps that swept
    /// range — and the "fast paddle adds speed" boost — well-behaved on a re-tap.
    func stepPaddle(dt: Double) {
        prevPaddleX = paddleX
        prevPaddleY = paddleY
        // Frame-rate-INDEPENDENT exponential easing. The old `min(dt * rate, 1)`
        // form looks smooth at iOS's steady 60fps (dt ~ 16ms gives a ~0.4 step) but
        // collapses into a jump on Android: there Breakout's heavier per-frame work
        // makes dt larger and more variable, and once dt >= 1/rate the linear step
        // saturates at 1.0 — so the single tick after a re-tap teleports the paddle
        // straight to the target. `1 - exp(-rate * dt)` instead advances the SAME
        // fraction per unit time no matter how big dt is, so the glide always spans
        // the same ~0.14s of wall-clock (several frames) on both platforms.
        let lerpStep = 1.0 - exp(-paddleFollowRate * dt)
        paddleX = paddleX + (paddleTargetX - paddleX) * lerpStep
        paddleY = paddleY + (paddleTargetY - paddleY) * lerpStep
    }

    /// Step the primary (scalar) ball. Returns true if the ball was lost this frame.
    private func stepPrimaryBall(dt: Double, speedScale: Double) -> Bool {
        let prevBallX = ballX
        let prevBallY = ballY
        ballX += ballDX * dt * speedScale
        ballY += ballDY * dt * speedScale

        if ballX - ballRadius < 0.0 {
            ballX = ballRadius
            ballDX = abs(ballDX)
        } else if ballX + ballRadius > fieldWidth {
            ballX = fieldWidth - ballRadius
            ballDX = -abs(ballDX)
        }

        if ballY - ballRadius < 0.0 {
            ballY = ballRadius
            ballDY = abs(ballDY)
        }

        // Paddle collision — swept against the paddle's motion this tick so a
        // fast-moving paddle (drag through the ball) can't tunnel past, and
        // a fast-moving ball can't pass through a stationary paddle.
        let paddleTop = paddleY - paddleHeight / 2.0
        let paddleLeft = paddleX - paddleWidth / 2.0
        let paddleRight = paddleX + paddleWidth / 2.0
        let prevPaddleTop = prevPaddleY - paddleHeight / 2.0
        let prevBallBottom = prevBallY + ballRadius
        let currBallBottom = ballY + ballRadius

        // Two cases catch tunnelling. Either:
        //  (a) the ball's bottom went from above the paddle's top to at/below
        //      the paddle's top this tick (covers fast ball + fast upward paddle),
        //      OR
        //  (b) the static check still passes — ball is currently inside the
        //      paddle's bounce window. Keeps the existing behaviour when neither
        //      object is moving fast.
        let crossedDown = prevBallBottom <= prevPaddleTop && currBallBottom >= paddleTop
        let staticOverlap = ballDY > 0.0 && currBallBottom >= paddleTop && currBallBottom <= paddleTop + paddleHeight + 4.0

        if ballDY > 0.0 && (crossedDown || staticOverlap) {
            // Horizontal: check overlap against the SWEPT paddle X range (its
            // left/right edges traced from prev to current position).
            let sweptLeft = min(prevPaddleX, paddleX) - paddleWidth / 2.0
            let sweptRight = max(prevPaddleX, paddleX) + paddleWidth / 2.0

            if ballX >= sweptLeft - ballRadius && ballX <= sweptRight + ballRadius {
                let incomingAngle = atan2(ballDX, ballDY)
                ballY = paddleTop - ballRadius
                let hitPos = (ballX - paddleX) / (paddleWidth / 2.0)
                let clampedHit = min(max(hitPos, -0.95), 0.95)
                let maxAngle = 1.15
                let outAngle = clampedHit * maxAngle

                // Speed boost: a paddle that's moving UP into the ball at the
                // moment of impact transfers some of its own speed to the ball,
                // so a "smash" with a quick upward swipe punches the ball
                // harder than a flat tap. Downward paddle motion doesn't slow
                // the ball — that would feel deadening.
                let paddleVy = dt > 0.0 ? (paddleY - prevPaddleY) / dt : 0.0
                let upwardSpeed = max(0.0, -paddleVy)
                let boost = min(upwardSpeed * 0.45, currentSpeed() * 0.6)
                let speed = currentSpeed() + boost

                ballDX = speed * sin(outAngle)
                ballDY = -speed * cos(outAngle)
                let mirrorAngle = -incomingAngle
                let angleDiff = abs(outAngle - mirrorAngle)
                let maxPossibleDiff = 2.0 * maxAngle
                lastPaddleDeflection = min(angleDiff / maxPossibleDiff, 1.0)
                // Paddle bounce breaks combos.
                combo = 0
            }
        } else {
            // "Smash from above" — the paddle was ABOVE the ball and its
            // bottom edge crashed down through the ball's top this tick.
            // Without this, dragging the paddle quickly downward into a ball
            // that was below it lets the paddle pass right through. Instead
            // we punt the ball further DOWN with a boost proportional to the
            // paddle's downward speed.
            let prevPaddleBottom = prevPaddleY + paddleHeight / 2.0
            let paddleBottom = paddleY + paddleHeight / 2.0
            let prevBallTop = prevBallY - ballRadius
            let currBallTop = ballY - ballRadius
            let smashedDown = prevBallTop >= prevPaddleBottom && currBallTop <= paddleBottom

            if smashedDown {
                let sweptLeft = min(prevPaddleX, paddleX) - paddleWidth / 2.0
                let sweptRight = max(prevPaddleX, paddleX) + paddleWidth / 2.0

                if ballX >= sweptLeft - ballRadius && ballX <= sweptRight + ballRadius {
                    // Park the ball just under the paddle so it can't end the
                    // tick still overlapping (which would re-trigger next frame).
                    ballY = paddleBottom + ballRadius
                    let hitPos = (ballX - paddleX) / (paddleWidth / 2.0)
                    let clampedHit = min(max(hitPos, -0.95), 0.95)
                    let maxAngle = 1.15
                    let outAngle = clampedHit * maxAngle

                    // Mirror of the upward boost, but more aggressive — a
                    // deliberate downward slam should noticeably accelerate
                    // the ball toward the death zone.
                    let paddleVy = dt > 0.0 ? (paddleY - prevPaddleY) / dt : 0.0
                    let downwardSpeed = max(0.0, paddleVy)
                    let boost = min(downwardSpeed * 0.6, currentSpeed() * 0.8)
                    let speed = currentSpeed() + boost

                    ballDX = speed * sin(outAngle)
                    ballDY = speed * cos(outAngle) // positive = downward
                    // Loud combo break + max deflection signal so the haptic
                    // engine fires the "hard hit" pattern.
                    combo = 0
                    lastPaddleDeflection = 1.0
                }
            }
        }

        if ballY - ballRadius > fieldHeight {
            return true
        }

        // Brick collisions (primary ball only — extras don't break combos but still award score)
        checkBrickCollisionsForPrimary()
        return false
    }

    /// Step an extra ball. Returns true if lost this frame.
    private func stepBall(ball b: Ball, dt: Double, speedScale: Double) -> Bool {
        let prevBallY = b.y
        b.x += b.dx * dt * speedScale
        b.y += b.dy * dt * speedScale

        if b.x - ballRadius < 0.0 {
            b.x = ballRadius
            b.dx = abs(b.dx)
        } else if b.x + ballRadius > fieldWidth {
            b.x = fieldWidth - ballRadius
            b.dx = -abs(b.dx)
        }

        if b.y - ballRadius < 0.0 {
            b.y = ballRadius
            b.dy = abs(b.dy)
        }

        // Paddle bounce — swept against the paddle's motion (same tunnelling
        // fix as the primary ball, just without the deflection/combo state).
        let paddleTop = paddleY - paddleHeight / 2.0
        let prevPaddleTop = prevPaddleY - paddleHeight / 2.0
        let prevBallBottom = prevBallY + ballRadius
        let currBallBottom = b.y + ballRadius
        let crossedDown = prevBallBottom <= prevPaddleTop && currBallBottom >= paddleTop
        let staticOverlap = b.dy > 0.0 && currBallBottom >= paddleTop && currBallBottom <= paddleTop + paddleHeight + 4.0

        if b.dy > 0.0 && (crossedDown || staticOverlap) {
            let sweptLeft = min(prevPaddleX, paddleX) - paddleWidth / 2.0
            let sweptRight = max(prevPaddleX, paddleX) + paddleWidth / 2.0
            if b.x >= sweptLeft - ballRadius && b.x <= sweptRight + ballRadius {
                b.y = paddleTop - ballRadius
                let hitPos = (b.x - paddleX) / (paddleWidth / 2.0)
                let clampedHit = min(max(hitPos, -0.95), 0.95)
                let maxAngle = 1.15
                let outAngle = clampedHit * maxAngle
                let paddleVy = dt > 0.0 ? (paddleY - prevPaddleY) / dt : 0.0
                let upwardSpeed = max(0.0, -paddleVy)
                let boost = min(upwardSpeed * 0.45, currentSpeed() * 0.6)
                let speed = currentSpeed() + boost
                b.dx = speed * sin(outAngle)
                b.dy = -speed * cos(outAngle)
            }
        } else {
            // Mirror of the smash-from-above check on the primary ball: a
            // paddle dragged downward through an extra ball below it should
            // knock the ball further down instead of slipping through.
            let prevPaddleBottom = prevPaddleY + paddleHeight / 2.0
            let paddleBottom = paddleY + paddleHeight / 2.0
            let prevBallTop = prevBallY - ballRadius
            let currBallTop = b.y - ballRadius
            let smashedDown = prevBallTop >= prevPaddleBottom && currBallTop <= paddleBottom

            if smashedDown {
                let sweptLeft = min(prevPaddleX, paddleX) - paddleWidth / 2.0
                let sweptRight = max(prevPaddleX, paddleX) + paddleWidth / 2.0
                if b.x >= sweptLeft - ballRadius && b.x <= sweptRight + ballRadius {
                    b.y = paddleBottom + ballRadius
                    let hitPos = (b.x - paddleX) / (paddleWidth / 2.0)
                    let clampedHit = min(max(hitPos, -0.95), 0.95)
                    let maxAngle = 1.15
                    let outAngle = clampedHit * maxAngle
                    let paddleVy = dt > 0.0 ? (paddleY - prevPaddleY) / dt : 0.0
                    let downwardSpeed = max(0.0, paddleVy)
                    let boost = min(downwardSpeed * 0.6, currentSpeed() * 0.8)
                    let speed = currentSpeed() + boost
                    b.dx = speed * sin(outAngle)
                    b.dy = speed * cos(outAngle) // positive = downward
                }
            }
        }

        if b.y - ballRadius > fieldHeight {
            return true
        }

        // Brick collisions for extra (no combo tracking, full score)
        checkBrickCollisionsForExtra(ball: b)
        return false
    }

    private func checkBrickCollisionsForPrimary() {
        let smashActive = smashBallTimer > 0.0
        for r in 0..<brickRows {
            for c in 0..<brickCols {
                let brick = bricks[r][c]
                if !brick.alive { continue }

                let bx = brickAreaLeft + Double(c) * (brickWidth + brickSpacing)
                let by = brickTopMargin + Double(r) * (brickHeight + brickSpacing)

                let closestX = min(max(ballX, bx), bx + brickWidth)
                let closestY = min(max(ballY, by), by + brickHeight)
                let dx = ballX - closestX
                let dy = ballY - closestY
                let distSq = dx * dx + dy * dy

                if distSq < ballRadius * ballRadius {
                    if smashActive {
                        // Smash-ball flatlines multi-hit bricks too — set HP to 1
                        // so onBrickHit's decrement lands at 0 in one shot. The ball
                        // continues straight through, so keep scanning for more bricks.
                        brick.hp = 1
                        onBrickHit(brick: brick, brickX: bx, brickY: by, fromPrimary: true)
                        continue
                    }
                    onBrickHit(brick: brick, brickX: bx, brickY: by, fromPrimary: true)

                    let overlapLeft = (ballX + ballRadius) - bx
                    let overlapRight = (bx + brickWidth) - (ballX - ballRadius)
                    let overlapTop = (ballY + ballRadius) - by
                    let overlapBottom = (by + brickHeight) - (ballY - ballRadius)

                    let minOverlapX = min(overlapLeft, overlapRight)
                    let minOverlapY = min(overlapTop, overlapBottom)

                    if minOverlapX < minOverlapY {
                        ballDX = -ballDX
                        if overlapLeft < overlapRight {
                            ballX = bx - ballRadius
                        } else {
                            ballX = bx + brickWidth + ballRadius
                        }
                    } else {
                        ballDY = -ballDY
                        if overlapTop < overlapBottom {
                            ballY = by - ballRadius
                        } else {
                            ballY = by + brickHeight + ballRadius
                        }
                    }
                    return
                }
            }
        }
    }

    private func checkBrickCollisionsForExtra(ball b: Ball) {
        let smashActive = smashBallTimer > 0.0
        for r in 0..<brickRows {
            for c in 0..<brickCols {
                let brick = bricks[r][c]
                if !brick.alive { continue }

                let bx = brickAreaLeft + Double(c) * (brickWidth + brickSpacing)
                let by = brickTopMargin + Double(r) * (brickHeight + brickSpacing)

                let closestX = min(max(b.x, bx), bx + brickWidth)
                let closestY = min(max(b.y, by), by + brickHeight)
                let dx = b.x - closestX
                let dy = b.y - closestY
                let distSq = dx * dx + dy * dy

                if distSq < ballRadius * ballRadius {
                    if smashActive {
                        brick.hp = 1
                        onBrickHit(brick: brick, brickX: bx, brickY: by, fromPrimary: false)
                        continue
                    }
                    onBrickHit(brick: brick, brickX: bx, brickY: by, fromPrimary: false)

                    let overlapLeft = (b.x + ballRadius) - bx
                    let overlapRight = (bx + brickWidth) - (b.x - ballRadius)
                    let overlapTop = (b.y + ballRadius) - by
                    let overlapBottom = (by + brickHeight) - (b.y - ballRadius)

                    let minOverlapX = min(overlapLeft, overlapRight)
                    let minOverlapY = min(overlapTop, overlapBottom)

                    if minOverlapX < minOverlapY {
                        b.dx = -b.dx
                        if overlapLeft < overlapRight {
                            b.x = bx - ballRadius
                        } else {
                            b.x = bx + brickWidth + ballRadius
                        }
                    } else {
                        b.dy = -b.dy
                        if overlapTop < overlapBottom {
                            b.y = by - ballRadius
                        } else {
                            b.y = by + brickHeight + ballRadius
                        }
                    }
                    return
                }
            }
        }
    }

    /// Apply a brick hit: knock down HP, award score, spawn particles/popup,
    /// drop power-up if HP reaches zero, advance combo (primary only).
    private func onBrickHit(brick: BrickData, brickX: Double, brickY: Double, fromPrimary: Bool) {
        brick.hp -= 1
        let basePoints = rowPoints[brick.row]
        if brick.hp <= 0 {
            // Award points (with combo multiplier from primary hits)
            let multiplier: Int
            if fromPrimary {
                combo += 1
                comboDecay = comboDecayWindow
                multiplier = min(combo, comboCap)
                if combo >= comboMinDisplay {
                    lastComboFlash = 1.0
                }
            } else {
                multiplier = 1
            }
            let earned = basePoints * multiplier
            score += earned
            spawnParticles(centerX: brickX + brickWidth / 2.0,
                           centerY: brickY + brickHeight / 2.0,
                           color: rowColors[brick.row % rowColors.count])
            spawnPopup(x: brickX + brickWidth / 2.0,
                       y: brickY + brickHeight / 2.0,
                       text: multiplier > 1 ? "+\(earned) x\(multiplier)" : "+\(earned)",
                       color: rowColors[brick.row % rowColors.count])
            // Drop pre-assigned power-up, plus a small random chance for any brick
            // to drop one (a little nudge of generosity).
            if brick.powerUpKindRaw >= 0 {
                if let kind = PowerUpKind(rawValue: brick.powerUpKindRaw) {
                    fallingPowerUps.append(FallingPowerUp(
                        x: brickX + brickWidth / 2.0,
                        y: brickY + brickHeight / 2.0,
                        kind: kind))
                }
            } else if Double.random(in: 0.0...1.0) < powerUpDropChance * 0.25 {
                fallingPowerUps.append(FallingPowerUp(
                    x: brickX + brickWidth / 2.0,
                    y: brickY + brickHeight / 2.0,
                    kind: randomPowerUpKind()))
            }
        } else {
            // Just damaged — award smaller score, small popup
            score += 1
            spawnPopup(x: brickX + brickWidth / 2.0,
                       y: brickY + brickHeight / 2.0,
                       text: "+1",
                       color: (1.0, 1.0, 1.0))
            spawnSparks(centerX: brickX + brickWidth / 2.0,
                        centerY: brickY + brickHeight / 2.0,
                        color: rowColors[brick.row % rowColors.count])
        }
    }

    private func spawnParticles(centerX: Double, centerY: Double, color: (Double, Double, Double)) {
        let count = 9
        for k in 0..<count {
            let angle = Double(k) * (.pi * 2.0 / Double(count)) + Double.random(in: -0.2...0.2)
            let speed = Double.random(in: 80.0...170.0)
            let life = Double.random(in: particleLifeMin...particleLifeMax)
            particles.append(Particle(
                x: centerX, y: centerY,
                dx: cos(angle) * speed,
                dy: sin(angle) * speed - 40.0,
                life: life,
                color: color,
                size: Double.random(in: 2.2...3.6)))
        }
    }

    /// Smaller burst for a non-fatal hit on a multi-hit brick.
    private func spawnSparks(centerX: Double, centerY: Double, color: (Double, Double, Double)) {
        for _ in 0..<3 {
            let angle = Double.random(in: -.pi ... .pi)
            let speed = Double.random(in: 40.0...90.0)
            particles.append(Particle(
                x: centerX, y: centerY,
                dx: cos(angle) * speed,
                dy: sin(angle) * speed - 20.0,
                life: Double.random(in: 0.25...0.45),
                color: color,
                size: 2.0))
        }
    }

    private func spawnPopup(x: Double, y: Double, text: String, color: (Double, Double, Double)) {
        scorePopups.append(ScorePopup(x: x, y: y, text: text, color: color))
    }

    private func applyPowerUp(kind: PowerUpKind, at x: Double, y: Double) {
        score += powerUpCatchScore
        spawnPopup(x: x, y: y, text: "+\(powerUpCatchScore)", color: kind.color)
        switch kind {
        case .widePaddle:
            widePaddleTimer = widePaddleDuration
        case .slowBall:
            slowBallTimer = slowBallDuration
        case .multiBall:
            spawnMultiBall()
        case .extraLife:
            if lives < maxLives { lives += 1 }
            // Confetti burst at the paddle.
            for _ in 0..<14 {
                let angle = Double.random(in: -.pi ... .pi)
                let speed = Double.random(in: 90.0...190.0)
                particles.append(Particle(
                    x: paddleX, y: paddleY,
                    dx: cos(angle) * speed,
                    dy: sin(angle) * speed - 100.0,
                    life: Double.random(in: 0.6...1.0),
                    color: kind.color,
                    size: Double.random(in: 2.5...4.0)))
            }
        case .smashBall:
            smashBallTimer = smashBallDuration
            // Ignition flare at the ball's current position so the activation reads.
            for _ in 0..<10 {
                let angle = Double.random(in: -.pi ... .pi)
                let speed = Double.random(in: 60.0...160.0)
                particles.append(Particle(
                    x: ballX, y: ballY,
                    dx: cos(angle) * speed,
                    dy: sin(angle) * speed - 30.0,
                    life: Double.random(in: 0.35...0.7),
                    color: kind.color,
                    size: Double.random(in: 2.5...3.5)))
            }
        }
    }

    /// Split the primary ball into three: the original plus two extras at ±0.32 rad.
    private func spawnMultiBall() {
        let baseDx = ballDX
        let baseDy = ballDY
        let speed = sqrt(baseDx * baseDx + baseDy * baseDy)
        // Angle of motion (relative to vertical, going up = -y direction)
        let baseAngle = atan2(baseDx, -baseDy)
        let offsets: [Double] = [0.32, -0.32]
        for off in offsets {
            let a = baseAngle + off
            extraBalls.append(Ball(
                x: ballX, y: ballY,
                dx: speed * sin(a),
                dy: -speed * cos(a)))
        }
    }

    /// Linear prediction of where the primary ball will hit a side wall, ignoring
    /// bricks. Used purely as a player-facing visual aid.
    private func updatePrediction() {
        if ballDX == 0.0 || !isLaunched {
            predictedSide = -1
            return
        }
        let targetX: Double
        let side: Int
        if ballDX > 0.0 {
            targetX = fieldWidth - ballRadius
            side = 1
        } else {
            targetX = ballRadius
            side = 0
        }
        let dx = targetX - ballX
        let t = dx / ballDX
        if t <= 0.0 {
            predictedSide = -1
            return
        }
        let predY = ballY + ballDY * t
        // If the trajectory hits ceiling or paddle line first, the side prediction is moot.
        let paddleTop = paddleY - paddleHeight / 2.0
        if predY < ballRadius || predY > paddleTop {
            predictedSide = -1
            return
        }
        predictedSide = side
        predictedY = predY
    }

    private func currentSpeed() -> Double {
        // Slight speed increase as bricks are cleared
        let totalBricks = brickRows * brickCols
        var alive = 0
        for row in bricks {
            for brick in row {
                if brick.alive { alive += 1 }
            }
        }
        let cleared = totalBricks - alive
        return ballSpeed + Double(cleared) * 1.5
    }

    private func saveHighScore() {
        if score > highScore {
            highScore = score
            UserDefaults.standard.set(highScore, forKey: "breakout_highscore")
        }
    }

    // MARK: - State Persistence

    func makeSavedState() -> BreakoutSavedState {
        var brickAlive: [Bool] = []
        for r in 0..<bricks.count {
            for c in 0..<bricks[r].count {
                brickAlive.append(bricks[r][c].alive)
            }
        }
        return BreakoutSavedState(
            paddleX: paddleX,
            ballX: ballX,
            ballY: ballY,
            ballDX: ballDX,
            ballDY: ballDY,
            brickAlive: brickAlive,
            score: score,
            lives: lives,
            level: level,
            isGameOver: isGameOver,
            isLevelComplete: isLevelComplete,
            isLaunched: isLaunched
        )
    }

    func restoreState(_ state: BreakoutSavedState) {
        paddleX = state.paddleX
        prevPaddleX = paddleX
        prevPaddleY = paddleY
        paddleTargetX = paddleX
        paddleTargetY = paddleY
        ballX = state.ballX
        ballY = state.ballY
        ballDX = state.ballDX
        ballDY = state.ballDY
        score = state.score
        lives = state.lives
        level = state.level
        isGameOver = state.isGameOver
        isLevelComplete = state.isLevelComplete
        isLaunched = state.isLaunched
        highScore = UserDefaults.standard.integer(forKey: "breakout_highscore")
        ballSpeed = initialBallSpeed + Double(level - 1) * 25.0

        // Drop transient state — extras, power-ups, particles, timers don't
        // survive a save/restore cycle (they're cosmetic / short-lived).
        extraBalls.removeAll()
        ballTrail.removeAll()
        fallingPowerUps.removeAll()
        particles.removeAll()
        scorePopups.removeAll()
        widePaddleTimer = 0.0
        slowBallTimer = 0.0
        smashBallTimer = 0.0
        paddleWidth = basePaddleWidth
        combo = 0
        comboDecay = 0.0
        predictedSide = -1

        // Rebuild bricks and apply saved alive states.
        buildLevel()
        var idx = 0
        for r in 0..<bricks.count {
            for c in 0..<bricks[r].count {
                if idx < state.brickAlive.count {
                    if !state.brickAlive[idx] {
                        bricks[r][c].hp = 0
                    }
                    // alive bricks restore at full HP (acceptable for resume)
                }
                idx += 1
            }
        }
    }

    func saveState() {
        guard let data = try? JSONEncoder().encode(makeSavedState()) else { return }
        guard let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: "breakout_saved_state")
    }

    static func loadSavedState() -> BreakoutSavedState? {
        guard let json = UserDefaults.standard.string(forKey: "breakout_saved_state") else { return nil }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BreakoutSavedState.self, from: data)
    }

    static func clearSavedState() {
        UserDefaults.standard.removeObject(forKey: "breakout_saved_state")
    }
}

// MARK: - Game View

struct BreakoutGameView: View {
    @Binding var showInstructions: Bool
    @State private var game = BreakoutModel()
    @State private var tickTimer: Timer? = nil
    @State private var lastTick: Double = 0.0
    @State private var showSettings = false
    @State private var showPauseMenu = false
    @State private var debugText: String = "waiting for touch"
    @State private var debugTouchCount: Int = 0
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase
    @Environment(BreakoutSettings.self) var settings: BreakoutSettings

    func playHaptic(_ pattern: HapticPattern) {
        if settings.vibrations {
            HapticFeedback.play(pattern)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let _ = initField(geo: geo)

            // Outer ZStack so the modal overlays (pause/game-over/level-complete)
            // can be drawn OUTSIDE the gesture-handled play area. On Android, the
            // play area's DragGesture captures pointer events before any child
            // Buttons could react, leaving the pause dialog unresponsive.
            ZStack {
                VStack(spacing: 0) {
                    hudView
                        .frame(height: 44)

                    ZStack {
                        backgroundView

                        gameFieldView()

                        if !game.isLaunched && !game.isGameOver && !game.isLevelComplete {
                            launchPrompt
                        }

                        if settings.debugInfo {
                            VStack {
                                Spacer()
                                Text(debugText)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.green)
                                    .padding(6)
                                    .background(Color.black.opacity(0.7))
                                    .padding(.bottom, 100)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                debugTouchCount += 1
                                debugText = "drag #\(debugTouchCount) loc=(\(Int(value.location.x)),\(Int(value.location.y))) start=(\(Int(value.startLocation.x)),\(Int(value.startLocation.y))) paddleX=\(Int(game.paddleX)) paddleY=\(Int(game.paddleY)) launched=\(game.isLaunched) over=\(game.isGameOver)"

                                if game.isGameOver || game.isLevelComplete || showPauseMenu { return }

                                if !game.isLaunched {
                                    game.launch()
                                    playHaptic(.pick)
                                }

                                // Absolute control: the paddle tracks the touch
                                // point directly rather than moving relative to
                                // where the gesture began. Horizontally it centers
                                // on the finger; vertically it rides paddleTouchYOffset
                                // ABOVE the fingertip so it's never hidden under it.
                                // We set the TARGET only — stepPaddle() eases the
                                // paddle there each tick, so lifting and tapping a
                                // new spot glides the paddle across instead of
                                // teleporting it. Both axes use the same clamps as
                                // before (X within the walls, Y between paddleYMin
                                // and the bottom edge).
                                game.paddleTargetX = min(max(value.location.x, game.paddleWidth / 2.0),
                                                         game.fieldWidth - game.paddleWidth / 2.0)
                                game.paddleTargetY = max(game.paddleYMin,
                                                         min(game.paddleYMax, value.location.y - paddleTouchYOffset))
                            }
                    )
                }
                .background(Color(red: 0.04, green: 0.04, blue: 0.12).ignoresSafeArea())

                // Modal overlays — siblings of the gesture-handled VStack so their
                // buttons are not shadowed by the DragGesture on Android/Compose.
                if game.isLevelComplete {
                    levelCompleteOverlay
                }

                if game.isGameOver {
                    gameOverOverlay
                }

                if showPauseMenu && !game.isGameOver && !game.isLevelComplete {
                    pauseMenuOverlay
                }
            }
        }
        .navigationBarBackButtonHidden()
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
            #if SKIP
            .ignoresSafeArea(.container, edges: .top)
            #endif
        #endif
        // On iOS, defer system gestures from every edge so a swipe that
        // brushes the edge (paddle slide, ball launch from near the corner)
        // doesn't trip the home indicator / app switcher mid-game. The user
        // can still invoke them with a second deliberate swipe. Skip's
        // SkipUI marks the modifier @available(*, unavailable), so it's
        // limited to native iOS via #if !SKIP.
        #if !SKIP
        #if os(iOS)
        .defersSystemGestures(on: .all)
        #endif
        #endif
        .onAppear {
            if let state = BreakoutModel.loadSavedState() {
                game.restoreState(state)
                if !game.isGameOver && !game.isLevelComplete {
                    showPauseMenu = true
                }
            } else {
                game.newGame()
            }
            startTimer()
        }
        .onDisappear { stopTimer() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                game.saveState()
                stopTimer()
                if game.isLaunched && !game.isGameOver && !game.isLevelComplete {
                    showPauseMenu = true
                }
            } else if !showPauseMenu {
                startTimer()
            }
        }
        .sheet(isPresented: $showSettings) {
            BreakoutSettingsView(settings: settings)
                .presentationDetents([.medium, .large])
        }
    }

    private func initField(geo: GeometryProxy) -> Bool {
        game.setup(width: geo.size.width, height: geo.size.height)
        return true
    }

    // MARK: - Background

    var backgroundView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.06, blue: 0.16),
                    Color(red: 0.02, green: 0.02, blue: 0.08)
                ],
                startPoint: .top, endPoint: .bottom
            )
            // Soft radial glow centered above the paddle to give the playfield depth.
            RadialGradient(
                colors: [Color.white.opacity(0.04), Color.clear],
                center: .center,
                startRadius: 0,
                endRadius: 280
            )
            .allowsHitTesting(false)
        }
    }

    // MARK: - Game Field

    func gameFieldView() -> some View {
        // IMPORTANT: each visual layer below is wrapped in its OWN ZStack rather than
        // listed directly as a sibling here. SkipUI's ZStack composes its (flattened)
        // children in a positional loop without a per-child Compose `key()`, so the
        // remembered animation state behind `.position`/`.frame`/`.fill` is bound to a
        // child's INDEX in that loop, not its identity. When a layer's child count
        // changes mid-frame (a brick is destroyed, a particle spawns, the side guide
        // toggles), every element drawn after it shifts index and inherits a neighbour's
        // remembered `Animatable` — making the paddle jump and bricks flash a neighbouring
        // row's colour for a frame. Wrapping each layer collapses it to a SINGLE child of
        // this parent ZStack at a fixed index, so a count change inside one layer can no
        // longer shift the slots of the paddle, ball, or other layers. The bricks layer
        // additionally emits a fixed-length grid (see `brickCell`) so a destroyed brick
        // doesn't shift its sibling bricks either.
        ZStack(alignment: .topLeading) {
            // Side-wall guide markers (drawn under bricks so bricks don't get cluttered)
            ZStack(alignment: .topLeading) {
                if game.predictedSide >= 0 {
                    sideGuideMarker
                }
            }

            // Bricks — always emit a fixed brickRows×brickCols grid so a destroyed brick
            // keeps its slot (as a clear placeholder) instead of shifting siblings.
            ZStack(alignment: .topLeading) {
                ForEach(0..<brickRows, id: \.self) { r in
                    ForEach(0..<brickCols, id: \.self) { c in
                        brickCell(row: r, col: c)
                    }
                }
            }

            // Falling power-ups
            ZStack(alignment: .topLeading) {
                ForEach(0..<game.fallingPowerUps.count, id: \.self) { i in
                    if i < game.fallingPowerUps.count {
                        powerUpCapsuleView(p: game.fallingPowerUps[i])
                    }
                }
            }

            // Particles
            ZStack(alignment: .topLeading) {
                ForEach(0..<game.particles.count, id: \.self) { i in
                    if i < game.particles.count {
                        particleView(p: game.particles[i])
                    }
                }
            }

            // Score popups
            ZStack(alignment: .topLeading) {
                ForEach(0..<game.scorePopups.count, id: \.self) { i in
                    if i < game.scorePopups.count {
                        popupView(s: game.scorePopups[i])
                    }
                }
            }

            // Ball trail (primary)
            ZStack(alignment: .topLeading) {
                ForEach(0..<game.ballTrail.count, id: \.self) { i in
                    if i < game.ballTrail.count {
                        let p = game.ballTrail[i]
                        let frac = Double(i + 1) / Double(ballTrailMax + 1)
                        Circle()
                            .fill(Color.white.opacity(0.10 + 0.20 * frac))
                            .frame(width: (ballRadius * 2.0) * (0.35 + 0.55 * frac),
                                   height: (ballRadius * 2.0) * (0.35 + 0.55 * frac))
                            .position(x: p.0, y: p.1)
                    }
                }
            }

            // Primary ball
            ballView(x: game.ballX, y: game.ballY)

            // Extra balls
            ZStack(alignment: .topLeading) {
                ForEach(0..<game.extraBalls.count, id: \.self) { i in
                    if i < game.extraBalls.count {
                        let b = game.extraBalls[i]
                        ballView(x: b.x, y: b.y)
                    }
                }
            }

            // Paddle (drawn last so power-ups slide UNDER it as they get caught)
            paddleShape(atX: game.paddleX)

            // Power-up timer badges along the top of the playfield
            if game.widePaddleTimer > 0.0 || game.slowBallTimer > 0.0 || game.smashBallTimer > 0.0 {
                powerUpStatusBar
            }

            // Combo flash near the center top
            if game.combo >= comboMinDisplay {
                comboBadge
            }
        }
    }

    /// One cell of the fixed-length brick grid. Emits the brick when alive, or a tiny clear
    /// placeholder when not — keeping the bricks layer's child count constant at
    /// brickRows×brickCols so a destroyed brick can't shift the remembered render state of
    /// its sibling bricks (which would flash them a neighbouring row's colour). See the note
    /// in `gameFieldView`.
    @ViewBuilder func brickCell(row r: Int, col c: Int) -> some View {
        if game.bricks.count > r && game.bricks[r].count > c && game.bricks[r][c].alive {
            brickView(row: r, col: c)
        } else {
            Color.clear.frame(width: 1.0, height: 1.0)
        }
    }

    // MARK: - Side-wall guide

    /// A short glowing dash on the wall where the primary ball is predicted to next hit.
    var sideGuideMarker: some View {
        let side = game.predictedSide
        let y = game.predictedY
        let isRight = (side == 1)
        let baseColor = Color(red: 0.55, green: 0.85, blue: 1.0)
        // Brighten as the ball gets closer.
        let dist: Double
        if isRight {
            dist = max(0.0, game.fieldWidth - game.ballX)
        } else {
            dist = max(0.0, game.ballX)
        }
        let fadeWindow: Double = max(80.0, game.fieldWidth * 0.35)
        let intensity = 1.0 - min(dist / fadeWindow, 1.0) * 0.65
        let markerWidth: Double = 3.0
        let markerLength: Double = 26.0
        let x = isRight ? game.fieldWidth - markerWidth / 2.0 : markerWidth / 2.0
        return ZStack {
            // Glow halo
            RoundedRectangle(cornerRadius: 1.5)
                .fill(baseColor.opacity(0.18 * intensity))
                .frame(width: markerWidth * 4.0, height: markerLength + 14.0)
                .blur(radius: 4)
            // Core dash
            RoundedRectangle(cornerRadius: 1.5)
                .fill(baseColor.opacity(0.85 * intensity))
                .frame(width: markerWidth, height: markerLength)
        }
        .position(x: x, y: y)
        .allowsHitTesting(false)
    }

    // MARK: - Brick

    func brickView(row: Int, col: Int) -> some View {
        let brick = game.bricks[row][col]
        let x = game.brickAreaLeft + Double(col) * (game.brickWidth + brickSpacing)
        let y = brickTopMargin + Double(row) * (brickHeight + brickSpacing)
        let ci = row % rowColors.count
        let base = rowColors[ci]
        // Multi-hit bricks render slightly darker until damaged; once damaged
        // they brighten to their row color so progress is legible.
        let damageFrac: Double = brick.maxHp > 1
            ? Double(brick.maxHp - brick.hp) / Double(max(brick.maxHp - 1, 1))
            : 1.0
        let armor: Double = brick.maxHp > 1 ? (1.0 - damageFrac) * 0.35 : 0.0
        let r = max(base.0 - armor, 0.0)
        let g = max(base.1 - armor, 0.0)
        let b = max(base.2 - armor, 0.0)
        let baseColor = Color(red: r, green: g, blue: b)
        let lightColor = Color(red: min(r + 0.18, 1.0), green: min(g + 0.18, 1.0), blue: min(b + 0.18, 1.0))
        let darkColor = Color(red: max(r - 0.15, 0.0), green: max(g - 0.15, 0.0), blue: max(b - 0.15, 0.0))
        let hasPower = brick.powerUpKindRaw >= 0

        return ZStack {
            // Base
            RoundedRectangle(cornerRadius: 3)
                .fill(baseColor)
                .frame(width: game.brickWidth, height: brickHeight)
            // Multi-hit armor outline
            if brick.maxHp > 1 {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
                    .frame(width: game.brickWidth, height: brickHeight)
            }
            // Top highlight
            RoundedRectangle(cornerRadius: 3)
                .fill(lightColor)
                .frame(width: game.brickWidth - 2, height: brickHeight * 0.45)
                .offset(y: -brickHeight * 0.2)
            // Bottom shadow
            RoundedRectangle(cornerRadius: 3)
                .fill(darkColor)
                .frame(width: game.brickWidth - 2, height: brickHeight * 0.2)
                .offset(y: brickHeight * 0.35)
            // Power-up indicator: a tinted shine + a kind-specific glyph so the
            // player can read which kind of pickup a brick will drop.
            if hasPower {
                if let pkind = PowerUpKind(rawValue: brick.powerUpKindRaw) {
                    let pc = pkind.color
                    let tint = Color(red: pc.0, green: pc.1, blue: pc.2)
                    // Diagonal sheen across the brick in the kind's tint — gives a
                    // "candy"/shiny look that pulls the eye to the power-up brick.
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color.white.opacity(0.0), tint.opacity(0.75), Color.white.opacity(0.0)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: game.brickWidth * 0.95, height: brickHeight * 0.30)
                        .offset(y: -brickHeight * 0.18)
                        .blur(radius: 0.6)
                    // Faint outer halo in the kind's color
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(tint.opacity(0.85), lineWidth: 1.0)
                        .frame(width: game.brickWidth, height: brickHeight)
                    powerUpBrickGlyph(kind: pkind)
                }
            }
        }
        .position(x: x + game.brickWidth / 2.0, y: y + brickHeight / 2.0)
    }

    /// Small icon centered on a power-up brick, distinct per kind. Drawn in white
    /// so the silhouette reads against any row color; the tinted shine + halo on
    /// the brick itself carries the colour hint.
    @ViewBuilder
    func powerUpBrickGlyph(kind: PowerUpKind) -> some View {
        let glyphColor = Color.white.opacity(0.95)
        if kind == .widePaddle {
            // Wide bar with two end caps — suggests paddle widening.
            HStack(spacing: 1.5) {
                Circle().fill(glyphColor).frame(width: 2.5, height: 2.5)
                Capsule().fill(glyphColor).frame(width: 8, height: 2.5)
                Circle().fill(glyphColor).frame(width: 2.5, height: 2.5)
            }
        } else if kind == .multiBall {
            // Three small circles — three balls in flight.
            HStack(spacing: 1.5) {
                Circle().fill(glyphColor).frame(width: 2.6, height: 2.6)
                Circle().fill(glyphColor).frame(width: 2.6, height: 2.6)
                Circle().fill(glyphColor).frame(width: 2.6, height: 2.6)
            }
        } else if kind == .slowBall {
            // Ring — reads as a clock face / slowdown.
            Circle()
                .strokeBorder(glyphColor, lineWidth: 1.3)
                .frame(width: 6, height: 6)
        } else if kind == .extraLife {
            // Plus / cross — extra life.
            ZStack {
                Capsule().fill(glyphColor).frame(width: 7, height: 1.7)
                Capsule().fill(glyphColor).frame(width: 1.7, height: 7)
            }
        } else if kind == .smashBall {
            // 4-point burst — power / smash.
            ZStack {
                Capsule().fill(glyphColor).frame(width: 8, height: 1.6)
                Capsule().fill(glyphColor).frame(width: 1.6, height: 8)
                Capsule().fill(glyphColor).frame(width: 6, height: 1.3)
                    .rotationEffect(.degrees(45))
                Capsule().fill(glyphColor).frame(width: 6, height: 1.3)
                    .rotationEffect(.degrees(-45))
            }
        }
    }

    // MARK: - Ball

    func ballView(x: Double, y: Double) -> some View {
        let slow = game.slowBallTimer > 0.0
        let smash = game.smashBallTimer > 0.0
        let coreColor: Color
        let haloColor: Color
        let haloMultiplier: Double
        if smash {
            // Smash-ball: fiery, larger glow.
            coreColor = Color(red: 1.00, green: 0.78, blue: 0.30)
            haloColor = Color(red: 1.00, green: 0.45, blue: 0.10).opacity(0.55)
            haloMultiplier = 5.0
        } else if slow {
            coreColor = Color(red: 0.70, green: 0.85, blue: 1.0)
            haloColor = Color(red: 0.55, green: 0.75, blue: 1.0).opacity(0.40)
            haloMultiplier = 3.6
        } else {
            coreColor = Color.white
            haloColor = Color.white.opacity(0.22)
            haloMultiplier = 3.6
        }
        return ZStack {
            Circle()
                .fill(haloColor)
                .frame(width: ballRadius * haloMultiplier, height: ballRadius * haloMultiplier)
                .blur(radius: smash ? 6.0 : 4.0)
            Circle()
                .fill(coreColor)
                .frame(width: ballRadius * 2.0, height: ballRadius * 2.0)
        }
        .position(x: x, y: y)
    }

    // MARK: - Paddle

    func paddleShape(atX px: Double) -> some View {
        let y = game.paddleY
        let wide = game.widePaddleTimer > 0.0
        let coreTop = wide ? Color(red: 0.55, green: 0.85, blue: 1.0) : Color(red: 0.70, green: 0.75, blue: 0.85)
        let coreBot = wide ? Color(red: 0.20, green: 0.55, blue: 0.95) : Color(red: 0.45, green: 0.50, blue: 0.65)
        return ZStack {
            // Glow when widened
            if wide {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.30, green: 0.70, blue: 0.95).opacity(0.35))
                    .frame(width: game.paddleWidth + 14, height: paddleHeight + 10)
                    .blur(radius: 6)
            }
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: [coreTop, coreBot], startPoint: .top, endPoint: .bottom))
                .frame(width: game.paddleWidth, height: paddleHeight)
            // Top shine
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.35))
                .frame(width: game.paddleWidth - 6, height: paddleHeight * 0.35)
                .offset(y: -paddleHeight * 0.2)
        }
        .position(x: px, y: y)
    }

    // MARK: - Particles, popups, capsules

    func particleView(p: Particle) -> some View {
        let alpha = max(0.0, min(p.life / p.maxLife, 1.0))
        return Circle()
            .fill(Color(red: p.r, green: p.g, blue: p.b).opacity(alpha))
            .frame(width: p.size, height: p.size)
            .position(x: p.x, y: p.y)
    }

    func popupView(s: ScorePopup) -> some View {
        let alpha = max(0.0, min(s.life / popupLife, 1.0))
        return Text(s.text)
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .foregroundStyle(Color(red: s.r, green: s.g, blue: s.b).opacity(alpha))
            .shadow(color: Color.black.opacity(0.5 * alpha), radius: 2, x: 0, y: 1)
            .position(x: s.x, y: s.y)
            .allowsHitTesting(false)
    }

    func powerUpCapsuleView(p: FallingPowerUp) -> some View {
        let kind = p.kind
        let c = kind.color
        let fill = Color(red: c.0, green: c.1, blue: c.2)
        return ZStack {
            // Halo
            Capsule()
                .fill(fill.opacity(0.40))
                .frame(width: powerUpWidth + 12, height: powerUpHeight + 10)
                .blur(radius: 6)
            // Body
            Capsule()
                .fill(LinearGradient(
                    colors: [fill.opacity(0.95), fill.opacity(0.65)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: powerUpWidth, height: powerUpHeight)
            Capsule()
                .strokeBorder(Color.white.opacity(0.75), lineWidth: 1)
                .frame(width: powerUpWidth, height: powerUpHeight)
            // Letter
            Text(kind.letter)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.white)
        }
        .position(x: p.x, y: p.y)
    }

    // MARK: - Status bar (active power-up timers)

    var powerUpStatusBar: some View {
        VStack {
            HStack(spacing: 8) {
                if game.widePaddleTimer > 0.0 {
                    timerBadge(kind: PowerUpKind.widePaddle,
                               remaining: game.widePaddleTimer,
                               total: widePaddleDuration)
                }
                if game.slowBallTimer > 0.0 {
                    timerBadge(kind: PowerUpKind.slowBall,
                               remaining: game.slowBallTimer,
                               total: slowBallDuration)
                }
                if game.smashBallTimer > 0.0 {
                    timerBadge(kind: PowerUpKind.smashBall,
                               remaining: game.smashBallTimer,
                               total: smashBallDuration)
                }
            }
            .padding(.top, 6)
            Spacer()
        }
    }

    func timerBadge(kind: PowerUpKind, remaining: Double, total: Double) -> some View {
        let frac = max(0.0, min(remaining / total, 1.0))
        let c = kind.color
        let color = Color(red: c.0, green: c.1, blue: c.2)
        return HStack(spacing: 4) {
            Text(kind.letter)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.white)
                .frame(width: 14, height: 14)
                .background(Circle().fill(color))
            // Time bar
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(color.opacity(0.85))
                        .frame(width: g.size.width * frac)
                }
            }
            .frame(width: 38, height: 5)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.55))
        )
    }

    // MARK: - Combo badge

    var comboBadge: some View {
        let multiplier = min(game.combo, comboCap)
        return VStack {
            Spacer().frame(height: 30)
            Text("x\(multiplier)")
                .font(.system(size: 26, weight: .black, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.yellow, Color.orange],
                        startPoint: .top, endPoint: .bottom)
                )
                .shadow(color: Color.orange.opacity(0.7), radius: 6, x: 0, y: 0)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(Color.black.opacity(0.45))
                )
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    // MARK: - HUD

    var hudView: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Image("cancel", bundle: .module)
                    .font(.title2)
                    .foregroundStyle(Color.white.opacity(0.6))
            }

            Spacer()

            Text("SCORE: \(game.score)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(Color.white)
                .monospaced()

            Spacer()

            // Lives as dots
            HStack(spacing: 4) {
                ForEach(0..<game.lives, id: \.self) { _ in
                    Circle()
                        .fill(Color(red: 0.9, green: 0.3, blue: 0.3))
                        .frame(width: 10, height: 10)
                }
            }

            Spacer()

            Text("LV \(game.level)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(Color.white.opacity(0.7))
                .monospaced()

            Button(action: {
                showPauseMenu = true
                stopTimer()
            }) {
                Image("pause_circle", bundle: .module)
                    .font(.title2)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(red: 0.04, green: 0.04, blue: 0.12))
    }

    // MARK: - Launch Prompt

    var launchPrompt: some View {
        VStack(spacing: 8) {
            Text("TAP TO LAUNCH", bundle: .module)
                .font(.headline)
                .fontWeight(.black)
                .foregroundStyle(Color.white)
                .shadow(color: .black.opacity(0.4), radius: 2, x: 1, y: 1)
            Text("DRAG TO MOVE PADDLE", bundle: .module)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(Color.white.opacity(0.6))
        }
    }

    // MARK: - Pause Menu

    var pauseMenuOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("PAUSED", bundle: .module)
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundStyle(Color.white)

                Button(action: {
                    showPauseMenu = false
                    startTimer()
                }) {
                    Text("Resume", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button(action: {
                    showPauseMenu = false
                    BreakoutModel.clearSavedState()
                    game.newGame()
                    startTimer()
                    playHaptic(.snap)
                }) {
                    Text("New Game", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.30, green: 0.55, blue: 0.95))

                Button(action: {
                    showPauseMenu = false
                    showSettings = true
                }) {
                    Text("Settings", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.3, green: 0.4, blue: 0.6))

                Button(action: {
                    showPauseMenu = false
                    showInstructions = true
                }) {
                    Text("Instructions", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.4, green: 0.4, blue: 0.7))

                Button(action: { dismiss() }) {
                    Text("Quit Game", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.18))
            )
        }
    }

    // MARK: - Level Complete

    var levelCompleteOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("LEVEL \(game.level) CLEAR!")
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundStyle(Color.yellow)

                VStack(spacing: 4) {
                    Text("Score", bundle: .module)
                        .font(.headline)
                        .foregroundStyle(Color.white.opacity(0.7))
                    Text("\(game.score)")
                        .font(.system(size: 40))
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                        .monospaced()
                }

                Button(action: {
                    BreakoutModel.clearSavedState()
                    game.startLevel(lvl: game.level + 1)
                    startTimer()
                    playHaptic(.snap)
                }) {
                    Text("Next Level", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                        .frame(width: 180, height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(red: 0.2, green: 0.6, blue: 0.3))
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.18))
            )
        }
    }

    // MARK: - Game Over

    var gameOverOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("GAME OVER", bundle: .module)
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundStyle(Color.white)

                VStack(spacing: 4) {
                    Text("Score", bundle: .module)
                        .font(.headline)
                        .foregroundStyle(Color.white.opacity(0.7))
                    Text("\(game.score)")
                        .font(.system(size: 44))
                        .fontWeight(.bold)
                        .foregroundStyle(Color.yellow)
                        .monospaced()
                }

                HStack(spacing: 24) {
                    VStack(spacing: 2) {
                        Text("Level", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.6))
                        Text("\(game.level)")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.white)
                    }
                    VStack(spacing: 2) {
                        Text("Best", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.6))
                        Text("\(game.highScore)")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.white)
                    }
                }

                if game.score >= game.highScore && game.score > 0 {
                    Text("New High Score!", bundle: .module)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.yellow)
                }

                Button(action: {
                    BreakoutModel.clearSavedState()
                    game.newGame()
                    startTimer()
                    playHaptic(.snap)
                }) {
                    Text("Play Again", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .padding(.top, 4)

                Button(action: { dismiss() }) {
                    Text("Quit Game", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                ShareLink(
                    item: "I scored \(game.score) (level \(game.level)) in Breakout on Faire Games! Can you beat it?\nhttps://appfair.net",
                    subject: Text("Breakout Score", bundle: .module),
                    message: Text("I scored \(game.score) in Breakout!")
                ) {
                    Label { Text("Share", bundle: .module) } icon: { Image(systemName: "square.and.arrow.up") }
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.18))
            )
        }
    }

    // MARK: - Timer

    func startTimer() {
        stopTimer()
        lastTick = currentTime()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            tick()
        }
    }

    func stopTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    func tick() {
        let now = currentTime()
        var dt = now - lastTick
        lastTick = now
        if dt > 0.1 { dt = 0.016 }

        if showPauseMenu { return }

        // Ease the paddle toward the touch target before the physics step so the
        // ball collides with the paddle at its actual (eased) position this frame.
        game.stepPaddle(dt: dt)

        let wasBrickCount = aliveBrickCount()
        game.update(dt: dt)
        let nowBrickCount = aliveBrickCount()

        if nowBrickCount < wasBrickCount {
            playHaptic(.snap)
        }

        if game.lastPaddleDeflection >= 0.0 {
            let deflection = game.lastPaddleDeflection
            let intensity = 1.0 - deflection * 0.7
            if deflection < 0.15 {
                HapticFeedback.play(HapticPattern([
                    HapticEvent(.thud, intensity: intensity),
                    HapticEvent(.tap, intensity: intensity * 0.7, delay: 0.04),
                ]))
            } else if deflection < 0.5 {
                HapticFeedback.play(HapticPattern([
                    HapticEvent(.tap, intensity: intensity),
                ]))
            } else {
                HapticFeedback.play(HapticPattern([
                    HapticEvent(.tick, intensity: intensity),
                ]))
            }
        }

        if game.isGameOver {
            playHaptic(.impact)
            stopTimer()
        }
    }

    func aliveBrickCount() -> Int {
        var count = 0
        for row in game.bricks {
            for brick in row {
                if brick.alive { count += 1 }
            }
        }
        return count
    }

    func currentTime() -> Double {
        return Date().timeIntervalSince1970
    }
}

// MARK: - Preview Icon

public struct BreakoutPreviewIcon: View {
    public init() { }

    public var body: some View {
        ZStack {
            // Dark background
            Color(red: 0.04, green: 0.04, blue: 0.12)

            // Mini brick rows
            VStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { r in
                    HStack(spacing: 2) {
                        ForEach(0..<6, id: \.self) { c in
                            let ci = r % rowColors.count
                            let col = rowColors[ci]
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color(red: col.0, green: col.1, blue: col.2))
                                .frame(height: 6)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
            .padding(.top, 18)

            // Mini ball
            Circle()
                .fill(Color.white)
                .frame(width: 6, height: 6)
                .offset(y: 16)

            // Mini paddle
            VStack {
                Spacer()
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(red: 0.60, green: 0.65, blue: 0.75))
                    .frame(width: 30, height: 6)
                    .padding(.bottom, 14)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Settings

struct BreakoutSettingsView: View {
    @Bindable var settings: BreakoutSettings
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Breakout", bundle: .module)) {
                    Toggle(isOn: $settings.vibrations) { Text("Vibrations", bundle: .module) }
                }
                Section(header: Text("Debug", bundle: .module)) {
                    Toggle(isOn: $settings.debugInfo) { Text("Debug Information", bundle: .module) }
                }
                Section(header: Text("Data", bundle: .module)) {
                    Button(role: .destructive, action: {
                        resetBreakoutHighScore()
                    }) {
                        Text("Reset High Score", bundle: .module)
                    }
                }
            }
            .navigationTitle(Text("Settings", bundle: .module))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: { dismiss() }) { Text("Done", bundle: .module) }
                }
            }
        }
    }
}

@Observable
public class BreakoutSettings {
    public var vibrations: Bool = defaults.value(forKey: "breakoutVibrations", default: true) {
        didSet { defaults.set(vibrations, forKey: "breakoutVibrations") }
    }

    public var debugInfo: Bool = defaults.value(forKey: "breakoutDebugInfo", default: false) {
        didSet { defaults.set(debugInfo, forKey: "breakoutDebugInfo") }
    }

    public init() {
    }
}

nonisolated(unsafe) private let defaults = UserDefaults.standard

private extension UserDefaults {
    func value<T>(forKey key: String, default defaultValue: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? defaultValue
    }
}
