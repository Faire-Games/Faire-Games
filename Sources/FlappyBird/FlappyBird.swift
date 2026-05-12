// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import Observation
import SkipKit
import FaireGamesModel

public struct FlappyBirdContainerView: View {
    @State private var settings = FlappyBirdSettings()
    @State private var showInstructions: Bool = false
    private let instructionsConfig = GameInstructionsConfig(
        key: "FlappyBird.instructions",
        bundle: .module,
        firstLaunchKey: "instructionsShown_FlappyBird",
        title: "Flappy Bird"
    )

    public init() { }

    public var body: some View {
        FlappyBirdGameView(showInstructions: $showInstructions)
            .navigationTitle("")
            #if !os(macOS)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
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

public func resetFlappyBirdHighScore() {
    UserDefaults.standard.set(0, forKey: "flappybird_highscore")
}

// MARK: - Constants

private let birdSize: Double = 30.0
private let groundHeight: Double = 80.0
private let birdX: Double = 80.0
private let pipeWidth: Double = 52.0

/// Difficulty-dependent parameters. Difficulty ranges from 1 (easiest) to 10 (hardest).
/// Level 5 matches the original game feel.
private func effectiveGravity(_ difficulty: Int) -> Double {
    // 1 → 750, 5 → 950, 10 → 1200
    return 750.0 + Double(difficulty - 1) * 50.0
}

private func effectiveFlapVelocity(_ difficulty: Int) -> Double {
    // 1 → -290, 5 → -330, 10 → -380
    return -290.0 - Double(difficulty - 1) * 10.0
}

private func effectivePipeSpeed(_ difficulty: Int) -> Double {
    // 1 → 90, 5 → 130, 10 → 180
    return 90.0 + Double(difficulty - 1) * 10.0
}

private func effectivePipeGap(_ difficulty: Int) -> Double {
    // 1 → 210, 5 → 160, 10 → 115
    return 210.0 - Double(difficulty - 1) * 10.5
}

private func effectivePipeSpacing(_ difficulty: Int) -> Double {
    // 1 → 280, 5 → 210, 10 → 155
    return 280.0 - Double(difficulty - 1) * 14.0
}

// MARK: - Pipe Model

final class PipeData: Identifiable {
    let id: Int
    var x: Double
    let gapY: Double // center of the gap
    var scored: Bool

    init(id: Int, x: Double, gapY: Double) {
        self.id = id
        self.x = x
        self.gapY = gapY
        self.scored = false
    }
}

// MARK: - Saved State

struct FlappyBirdSavedState: Codable {
    var birdY: Double
    var birdVelocity: Double
    var birdRotation: Double
    var pipeIds: [Int]
    var pipeXs: [Double]
    var pipeGapYs: [Double]
    var pipeScored: [Bool]
    var score: Int
    var isGameOver: Bool
    var hasStarted: Bool
    var difficulty: Int
}

// MARK: - Game Model

/// Radius for the rounded pipe corners (visual and collision)
private let pipeCornerRadius: Double = 8.0

/// How many pixels to forgive at pipe opening corners for collision
private let pipeCornerInset: Double = 6.0

@Observable
final class FlappyBirdModel {
    var birdY: Double = 0.0
    var birdVelocity: Double = 0.0
    var birdRotation: Double = 0.0
    var wingAngle: Double = 0.0 // -1 = up, 0 = mid, 1 = down
    var wingTimer: Double = 0.0
    var pipes: [PipeData] = []
    var score: Int = 0
    var highScore: Int = UserDefaults.standard.integer(forKey: "flappybird_highscore")
    var isGameOver: Bool = false
    var hasStarted: Bool = false
    /// What the bird crashed into: "pipe", "ground", "ceiling", or "" if alive
    var crashType: String = ""
    var fieldHeight: Double = 600.0
    var fieldWidth: Double = 400.0
    var difficulty: Int = 5

    var nextPipeID: Int = 0

    private var gravity: Double { effectiveGravity(difficulty) }
    private var flapVel: Double { effectiveFlapVelocity(difficulty) }
    private var speed: Double { effectivePipeSpeed(difficulty) }
    private var gap: Double { effectivePipeGap(difficulty) }
    private var spacing: Double { effectivePipeSpacing(difficulty) }

    func setup(width: Double, height: Double) {
        fieldWidth = width
        fieldHeight = height
    }

    func newGame() {
        birdY = fieldHeight * 0.4
        birdVelocity = 0.0
        birdRotation = 0.0
        wingAngle = 0.0
        wingTimer = 0.0
        pipes = []
        score = 0
        isGameOver = false
        hasStarted = false
        crashType = ""
        nextPipeID = 0
    }

    func flap() {
        if isGameOver { return }
        if !hasStarted {
            hasStarted = true
            spawnInitialPipes()
        }
        birdVelocity = flapVel
        wingTimer = 0.3 // start a flap cycle lasting 0.3s
        wingAngle = -1.0 // wing up
    }

    func update(dt: Double) {
        guard hasStarted && !isGameOver else { return }

        // Physics
        birdVelocity += gravity * dt
        birdY += birdVelocity * dt

        // Bird rotation: nose up at -25 when flapping, rotate down to +90 when falling
        let clampedVel = min(max(birdVelocity, flapVel), 400.0)
        birdRotation = ((clampedVel - flapVel) / (400.0 - flapVel)) * 115.0 - 25.0

        // Wing animation: flap cycle over 0.3s
        // -1 (up) → 0 (mid) → 1 (down) → 0 (mid, rest)
        if wingTimer > 0.0 {
            wingTimer -= dt
            if wingTimer <= 0.0 {
                wingTimer = 0.0
                wingAngle = 0.0
            } else {
                let t = 1.0 - wingTimer / 0.3 // 0→1 over the cycle
                if t < 0.33 {
                    wingAngle = -1.0 + t * 3.0 // -1 → 0
                } else if t < 0.66 {
                    wingAngle = (t - 0.33) * 3.0 // 0 → 1
                } else {
                    wingAngle = 1.0 - (t - 0.66) * 3.0 // 1 → 0
                }
            }
        }

        // Move pipes
        let dx = speed * dt
        for pipe in pipes {
            pipe.x -= dx
        }

        // Score — bird passes the trailing edge of a pipe
        for pipe in pipes {
            if !pipe.scored && pipe.x + pipeWidth < birdX {
                pipe.scored = true
                score += 1
            }
        }

        // Remove off-screen pipes
        pipes = pipes.filter { $0.x + pipeWidth > -10.0 }

        // Spawn new pipes
        if let last = pipes.last {
            if last.x < fieldWidth - spacing {
                spawnPipe(atX: fieldWidth + 20.0)
            }
        } else {
            spawnPipe(atX: fieldWidth + 20.0)
        }

        // Collision detection
        let playableHeight = fieldHeight - groundHeight

        // Ceiling
        if birdY - birdSize / 2.0 < 0.0 {
            crashType = "ceiling"
            gameOver()
            return
        }

        // Ground
        if birdY + birdSize / 2.0 > playableHeight {
            crashType = "ground"
            gameOver()
            return
        }

        // Pipes — with forgiving rounded corners
        let birdLeft = birdX - birdSize / 2.0
        let birdRight = birdX + birdSize / 2.0
        let birdTop = birdY - birdSize / 2.0
        let birdBottom = birdY + birdSize / 2.0

        for pipe in pipes {
            if birdRight > pipe.x && birdLeft < pipe.x + pipeWidth {
                let topPipeBottom = pipe.gapY - gap / 2.0
                let bottomPipeTop = pipe.gapY + gap / 2.0

                // Check if bird is in the gap — no collision
                if birdTop >= topPipeBottom && birdBottom <= bottomPipeTop {
                    continue
                }

                // Near the pipe opening corners, give extra forgiveness
                // by shrinking the collision zone horizontally
                let nearTopOpening = abs(birdBottom - topPipeBottom) < pipeCornerInset
                let nearBottomOpening = abs(birdTop - bottomPipeTop) < pipeCornerInset
                if nearTopOpening || nearBottomOpening {
                    let insetLeft = pipe.x + pipeCornerInset
                    let insetRight = pipe.x + pipeWidth - pipeCornerInset
                    if birdRight <= insetLeft || birdLeft >= insetRight {
                        continue // bird clips only the rounded corner — forgive it
                    }
                }

                // Solid collision
                if birdTop < topPipeBottom || birdBottom > bottomPipeTop {
                    crashType = "pipe"
                    gameOver()
                    return
                }
            }
        }
    }

    private func spawnInitialPipes() {
        var x = fieldWidth + 60.0
        for _ in 0..<3 {
            spawnPipe(atX: x)
            x += spacing
        }
    }

    private func spawnPipe(atX x: Double) {
        let playable = fieldHeight - groundHeight
        let margin = gap / 2.0 + 40.0
        let maxGap = playable - gap / 2.0 - 40.0
        let gapY = Double.random(in: margin...max(margin, maxGap))
        let pipe = PipeData(id: nextPipeID, x: x, gapY: gapY)
        nextPipeID += 1
        pipes.append(pipe)
    }

    private func gameOver() {
        isGameOver = true
        if score > highScore {
            highScore = score
            UserDefaults.standard.set(highScore, forKey: "flappybird_highscore")
        }
        saveState()
    }

    // MARK: - State Persistence

    func makeSavedState() -> FlappyBirdSavedState {
        var pipeIds: [Int] = []
        var pipeXs: [Double] = []
        var pipeGapYs: [Double] = []
        var pipeScored: [Bool] = []
        for pipe in pipes {
            pipeIds.append(pipe.id)
            pipeXs.append(pipe.x)
            pipeGapYs.append(pipe.gapY)
            pipeScored.append(pipe.scored)
        }
        return FlappyBirdSavedState(
            birdY: birdY,
            birdVelocity: birdVelocity,
            birdRotation: birdRotation,
            pipeIds: pipeIds,
            pipeXs: pipeXs,
            pipeGapYs: pipeGapYs,
            pipeScored: pipeScored,
            score: score,
            isGameOver: isGameOver,
            hasStarted: hasStarted,
            difficulty: difficulty
        )
    }

    func restoreState(_ state: FlappyBirdSavedState) {
        birdY = state.birdY
        birdVelocity = state.birdVelocity
        birdRotation = state.birdRotation
        score = state.score
        isGameOver = state.isGameOver
        hasStarted = state.hasStarted
        difficulty = state.difficulty
        highScore = UserDefaults.standard.integer(forKey: "flappybird_highscore")

        var restoredPipes: [PipeData] = []
        for i in 0..<state.pipeIds.count {
            let pipe = PipeData(id: state.pipeIds[i], x: state.pipeXs[i], gapY: state.pipeGapYs[i])
            pipe.scored = state.pipeScored[i]
            restoredPipes.append(pipe)
        }
        pipes = restoredPipes

        var maxId = 0
        for pipe in pipes {
            if pipe.id > maxId { maxId = pipe.id }
        }
        nextPipeID = maxId + 1
    }

    func saveState() {
        guard let data = try? JSONEncoder().encode(makeSavedState()) else { return }
        guard let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: "flappybird_saved_state")
    }

    static func loadSavedState() -> FlappyBirdSavedState? {
        guard let json = UserDefaults.standard.string(forKey: "flappybird_saved_state") else { return nil }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FlappyBirdSavedState.self, from: data)
    }

    static func clearSavedState() {
        UserDefaults.standard.removeObject(forKey: "flappybird_saved_state")
    }
}

// MARK: - Game View

struct FlappyBirdGameView: View {
    @Binding var showInstructions: Bool
    @State private var game = FlappyBirdModel()
    @State private var tickTimer: Timer? = nil
    @State private var lastTick: Double = 0.0
    @State private var showPauseMenu = false
    @State private var showSettings = false
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase
    @Environment(FlappyBirdSettings.self) var settings: FlappyBirdSettings

    func playHaptic(_ pattern: HapticPattern) {
        if settings.vibrations {
            HapticFeedback.play(pattern)
        }
    }

    func playFlapHaptic() {
        guard settings.vibrations else { return }
        // Strong, satisfying wing-flap thud
        HapticFeedback.play(HapticPattern([
            HapticEvent(.thud, intensity: 0.7),
            HapticEvent(.tap, intensity: 0.5, delay: 0.03),
        ]))
    }

    func playCrashHaptic(type: String) {
        guard settings.vibrations else { return }
        if type == "pipe" {
            // Dramatic pipe crash: sharp impact + rattling aftershock
            HapticFeedback.play(HapticPattern([
                HapticEvent(.thud, intensity: 1.0),
                HapticEvent(.thud, intensity: 1.0, delay: 0.04),
                HapticEvent(.tap, intensity: 0.9, delay: 0.05),
                HapticEvent(.thud, intensity: 0.7, delay: 0.06),
                HapticEvent(.tick, intensity: 0.5, delay: 0.06),
                HapticEvent(.tick, intensity: 0.3, delay: 0.05),
            ]))
        } else {
            // Ground/ceiling crash: single heavy slam + bounce
            HapticFeedback.play(HapticPattern([
                HapticEvent(.thud, intensity: 1.0),
                HapticEvent(.rise, intensity: 0.6, delay: 0.08),
                HapticEvent(.thud, intensity: 0.5, delay: 0.1),
                HapticEvent(.tick, intensity: 0.3, delay: 0.08),
            ]))
        }
    }

    var body: some View {
        GeometryReader { geo in
            let _ = initField(geo: geo)
            ZStack {
                // Sky background
                LinearGradient(
                    colors: [
                        Color(red: 0.30, green: 0.75, blue: 0.93),
                        Color(red: 0.55, green: 0.85, blue: 0.95)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                // Game field
                gameField(width: geo.size.width, height: geo.size.height)

                // HUD overlay
                headerView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8)

                // Tap to start
                if !game.hasStarted && !game.isGameOver {
                    startPrompt
                }

                // Game over
                if game.isGameOver {
                    gameOverOverlay
                }

                if showPauseMenu && !game.isGameOver {
                    pauseMenuOverlay
                }
            }
            .onTapGesture {
                if game.isGameOver || showPauseMenu { return }
                game.flap()
                playFlapHaptic()
            }
        }
        .navigationBarBackButtonHidden()
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear {
            game.difficulty = settings.difficulty
            if let saved = FlappyBirdModel.loadSavedState() {
                game.restoreState(saved)
                if saved.isGameOver {
                    // Show game over screen
                } else if saved.hasStarted {
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
                pauseGame()
                game.saveState()
            }
        }
        .sheet(isPresented: $showSettings) {
            FlappyBirdSettingsView(settings: settings)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: settings.difficulty) { _, newVal in
            game.difficulty = newVal
        }
    }

    private func initField(geo: GeometryProxy) -> Bool {
        game.setup(width: geo.size.width, height: geo.size.height)
        return true
    }

    // MARK: - Game Field

    func gameField(width: Double, height: Double) -> some View {
        let playableHeight = height - groundHeight

        return ZStack(alignment: .topLeading) {
            // Pipes
            ForEach(game.pipes) { pipe in
                pipeView(pipe: pipe, playableHeight: playableHeight)
            }

            // Bird
            birdView
                .position(x: birdX, y: game.birdY)

            // Ground
            groundView(width: width, height: height)
        }
    }

    // MARK: - Bird
    //
    // Chunky, slightly wider-than-tall yellow bird viewed from the side.
    // Body is an egg-shaped ellipse with a dark outline. A small wing
    // protrudes from the back of the body and flaps when the player taps.
    // wingAngle drives the wing position: -1 = raised, 0 = mid, 1 = lowered.

    var birdView: some View {
        let s = birdSize
        let w = s * 1.18 // slightly wider than tall, egg-shaped
        // Wing vertical offset driven by wingAngle (-1 up, 0 mid, 1 down)
        let wingY = game.wingAngle * s * 0.22

        return ZStack {
            // Dark outline — slightly larger ellipse behind the body
            Ellipse()
                .fill(Color(red: 0.20, green: 0.15, blue: 0.05))
                .frame(width: w + 4, height: s + 4)

            // Main body — warm yellow, egg-shaped
            Ellipse()
                .fill(Color(red: 0.98, green: 0.82, blue: 0.15))
                .frame(width: w, height: s)

            // Belly highlight — lighter yellow on the lower half
            Ellipse()
                .fill(Color(red: 1.0, green: 0.93, blue: 0.50))
                .frame(width: w * 0.50, height: s * 0.30)
                .offset(y: s * 0.18)

            // Wing — small rounded shape that moves up/down with the flap
            // Wing outline
            Ellipse()
                .fill(Color(red: 0.20, green: 0.15, blue: 0.05))
                .frame(width: s * 0.42, height: s * 0.28)
                .offset(x: -w * 0.22, y: s * 0.02 + wingY)
            // Wing fill
            Ellipse()
                .fill(Color(red: 0.90, green: 0.72, blue: 0.12))
                .frame(width: s * 0.38, height: s * 0.24)
                .offset(x: -w * 0.22, y: s * 0.02 + wingY)
            // Wing inner highlight
            Ellipse()
                .fill(Color(red: 1.0, green: 0.88, blue: 0.35))
                .frame(width: s * 0.22, height: s * 0.13)
                .offset(x: -w * 0.22, y: s * 0.00 + wingY)

            // Tail feathers — tiny dark mark at the back
            Ellipse()
                .fill(Color(red: 0.20, green: 0.15, blue: 0.05))
                .frame(width: s * 0.14, height: s * 0.22)
                .offset(x: -w * 0.52, y: -s * 0.02)
            Ellipse()
                .fill(Color(red: 0.75, green: 0.58, blue: 0.08))
                .frame(width: s * 0.10, height: s * 0.18)
                .offset(x: -w * 0.52, y: -s * 0.02)

            // Eye — large white circle with black pupil, positioned upper-front
            // Eye outline
            Circle()
                .fill(Color(red: 0.20, green: 0.15, blue: 0.05))
                .frame(width: s * 0.40, height: s * 0.40)
                .offset(x: w * 0.16, y: -s * 0.14)
            Circle()
                .fill(Color.white)
                .frame(width: s * 0.36, height: s * 0.36)
                .offset(x: w * 0.16, y: -s * 0.14)
            // Pupil — pushed toward the front
            Circle()
                .fill(Color.black)
                .frame(width: s * 0.17, height: s * 0.17)
                .offset(x: w * 0.24, y: -s * 0.13)

            // Beak — two-part, protruding from the front
            // Upper beak (orange-yellow)
            Ellipse()
                .fill(Color(red: 0.20, green: 0.15, blue: 0.05))
                .frame(width: s * 0.38, height: s * 0.20)
                .offset(x: w * 0.44, y: s * 0.04)
            Ellipse()
                .fill(Color(red: 0.96, green: 0.58, blue: 0.12))
                .frame(width: s * 0.34, height: s * 0.16)
                .offset(x: w * 0.44, y: s * 0.04)

            // Lower beak (darker red-orange)
            Ellipse()
                .fill(Color(red: 0.20, green: 0.15, blue: 0.05))
                .frame(width: s * 0.34, height: s * 0.16)
                .offset(x: w * 0.42, y: s * 0.15)
            Ellipse()
                .fill(Color(red: 0.88, green: 0.30, blue: 0.12))
                .frame(width: s * 0.30, height: s * 0.12)
                .offset(x: w * 0.42, y: s * 0.15)
        }
        .rotationEffect(.degrees(min(max(game.birdRotation, -25.0), 90.0)))
    }

    // MARK: - Pipes

    func pipeView(pipe: PipeData, playableHeight: Double) -> some View {
        let currentGap = effectivePipeGap(game.difficulty)
        let topHeight = pipe.gapY - currentGap / 2.0
        let bottomY = pipe.gapY + currentGap / 2.0
        let bottomHeight = playableHeight - bottomY

        return ZStack(alignment: .topLeading) {
            // Top pipe
            if topHeight > 0.0 {
                pipeRect(width: pipeWidth, height: topHeight)
                    .position(x: pipe.x + pipeWidth / 2.0, y: topHeight / 2.0)

                // Top pipe cap (lip at the opening)
                pipeCap(width: pipeWidth + 8.0)
                    .position(x: pipe.x + pipeWidth / 2.0, y: topHeight - 12.0)
            }

            // Bottom pipe
            if bottomHeight > 0.0 {
                pipeRect(width: pipeWidth, height: bottomHeight)
                    .position(x: pipe.x + pipeWidth / 2.0, y: bottomY + bottomHeight / 2.0)

                // Bottom pipe cap
                pipeCap(width: pipeWidth + 8.0)
                    .position(x: pipe.x + pipeWidth / 2.0, y: bottomY + 12.0)
            }
        }
    }

    func pipeRect(width: Double, height: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: pipeCornerRadius)
                .fill(Color(red: 0.32, green: 0.68, blue: 0.22))
                .frame(width: width, height: height)
            // Highlight stripe
            RoundedRectangle(cornerRadius: pipeCornerRadius - 2.0)
                .fill(Color(red: 0.42, green: 0.78, blue: 0.30))
                .frame(width: width * 0.3, height: height)
                .offset(x: -width * 0.15)
            // Shadow stripe
            RoundedRectangle(cornerRadius: pipeCornerRadius - 2.0)
                .fill(Color(red: 0.22, green: 0.55, blue: 0.15))
                .frame(width: width * 0.15, height: height)
                .offset(x: width * 0.35)
        }
    }

    func pipeCap(width: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: pipeCornerRadius)
                .fill(Color(red: 0.32, green: 0.68, blue: 0.22))
                .frame(width: width, height: 24)
            RoundedRectangle(cornerRadius: pipeCornerRadius - 2.0)
                .fill(Color(red: 0.42, green: 0.78, blue: 0.30))
                .frame(width: width * 0.3, height: 24)
                .offset(x: -width * 0.15)
        }
    }

    // MARK: - Ground

    func groundView(width: Double, height: Double) -> some View {
        VStack(spacing: 0) {
            Spacer()
            // Grass edge
            Rectangle()
                .fill(Color(red: 0.55, green: 0.78, blue: 0.22))
                .frame(height: 8)
            // Dirt
            Rectangle()
                .fill(Color(red: 0.84, green: 0.72, blue: 0.48))
                .frame(height: groundHeight - 8.0)
        }
        .frame(width: width, height: height)
    }

    // MARK: - HUD

    var headerView: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Image("cancel", bundle: .module)
                    .font(.title2)
                    .foregroundStyle(Color.white.opacity(0.8))
            }
            Spacer()

            // Score display
            VStack(spacing: 0) {
                Text("\(game.score)")
                    .font(.system(size: 40))
                    .fontWeight(.black)
                    .foregroundStyle(Color.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 1, y: 1)
            }

            Spacer()
            Button(action: { pauseGame() }) {
                Image("pause_circle", bundle: .module)
                    .font(.title2)
                    .foregroundStyle(Color.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Start Prompt

    var startPrompt: some View {
        VStack(spacing: 16) {
            Text("TAP TO FLY", bundle: .module)
                .font(.title)
                .fontWeight(.black)
                .foregroundStyle(Color.white)
                .shadow(color: .black.opacity(0.3), radius: 2, x: 1, y: 1)

            // Bouncing arrow hint
            Text("\u{25B2}", bundle: .module)
                .font(.largeTitle)
                .foregroundStyle(Color.white.opacity(0.7))
        }
    }

    // MARK: - Game Over

    var gameOverOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
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

                VStack(spacing: 2) {
                    Text("Best", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                    Text("\(game.highScore)")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                }

                VStack(spacing: 2) {
                    Text("Difficulty", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                    Text("\(game.difficulty)")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                }

                if game.score >= game.highScore && game.score > 0 {
                    Text("New High Score!", bundle: .module)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.yellow)
                }

                Button(action: {
                    FlappyBirdModel.clearSavedState()
                    game.difficulty = settings.difficulty
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
                    item: "I scored \(game.score) in Flappy Bird (difficulty \(game.difficulty)) on Faire Games! Can you beat it?\nhttps://appfair.net",
                    subject: Text("Flappy Bird Score", bundle: .module),
                    message: Text("I scored \(game.score) in Flappy Bird!")
                ) {
                    Label { Text("Share", bundle: .module) } icon: { Image(systemName: "square.and.arrow.up") }
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(red: 0.1, green: 0.1, blue: 0.2))
            )
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

                Button(action: { resumeGame() }) {
                    Text("Resume", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button(action: {
                    FlappyBirdModel.clearSavedState()
                    game.newGame()
                    showPauseMenu = false
                }) {
                    Text("New Game", bundle: .module)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.30, green: 0.55, blue: 0.95))

                Button(action: { showSettings = true }) {
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
                    .fill(Color(red: 0.1, green: 0.1, blue: 0.2))
            )
        }
    }

    func pauseGame() {
        guard !showPauseMenu else { return }
        stopTimer()
        showPauseMenu = true
    }

    func resumeGame() {
        showPauseMenu = false
        startTimer()
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

        // Clamp to avoid huge jumps after backgrounding
        if dt > 0.1 { dt = 0.016 }

        let wasAlive = !game.isGameOver
        game.update(dt: dt)

        if game.isGameOver && wasAlive {
            playCrashHaptic(type: game.crashType)
            stopTimer()
        }
    }

    func currentTime() -> Double {
        return Date().timeIntervalSince1970
    }
}

// MARK: - Preview Icon

public struct FlappyBirdPreviewIcon: View {
    public init() { }

    public var body: some View {
        ZStack {
            // Sky
            LinearGradient(
                colors: [
                    Color(red: 0.30, green: 0.75, blue: 0.93),
                    Color(red: 0.55, green: 0.85, blue: 0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Mini pipes
            HStack(spacing: 20) {
                miniPipe(gapOffset: -10.0)
                miniPipe(gapOffset: 8.0)
            }

            // Mini bird — egg-shaped yellow body, wing, white eye, orange beak
            ZStack {
                // Outline
                Ellipse()
                    .fill(Color(red: 0.20, green: 0.15, blue: 0.05))
                    .frame(width: 18, height: 16)
                // Body
                Ellipse()
                    .fill(Color(red: 0.98, green: 0.82, blue: 0.15))
                    .frame(width: 16, height: 14)
                // Wing
                Ellipse()
                    .fill(Color(red: 0.90, green: 0.72, blue: 0.12))
                    .frame(width: 6, height: 4)
                    .offset(x: -4, y: 1)
                // Eye
                Circle()
                    .fill(Color.white)
                    .frame(width: 5, height: 5)
                    .offset(x: 4, y: -2)
                Circle()
                    .fill(Color.black)
                    .frame(width: 2.5, height: 2.5)
                    .offset(x: 5, y: -1.5)
                // Beak
                Ellipse()
                    .fill(Color(red: 0.96, green: 0.58, blue: 0.12))
                    .frame(width: 6, height: 3)
                    .offset(x: 9, y: 1)
            }
            .offset(x: -8, y: -4)

            // Ground
            VStack {
                Spacer()
                Rectangle()
                    .fill(Color(red: 0.55, green: 0.78, blue: 0.22))
                    .frame(height: 3)
                Rectangle()
                    .fill(Color(red: 0.84, green: 0.72, blue: 0.48))
                    .frame(height: 16)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    func miniPipe(gapOffset: Double) -> some View {
        VStack(spacing: 28) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(red: 0.32, green: 0.68, blue: 0.22))
                .frame(width: 14, height: 30)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(red: 0.32, green: 0.68, blue: 0.22))
                .frame(width: 14, height: 30)
        }
        .offset(y: gapOffset)
    }
}

// MARK: - Settings

struct FlappyBirdSettingsView: View {
    @Bindable var settings: FlappyBirdSettings
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Flappy Bird", bundle: .module)) {
                    Toggle(isOn: $settings.vibrations) { Text("Vibrations", bundle: .module) }
                }
                Section(header: Text("Difficulty", bundle: .module)) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Level", bundle: .module)
                            Spacer()
                            Text("\(settings.difficulty)")
                                .foregroundStyle(Color.secondary)
                                .monospaced()
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.difficulty) },
                                set: { settings.difficulty = Int($0.rounded()) }
                            ),
                            in: 1.0...10.0,
                            step: 1.0
                        )
                        HStack {
                            Text("Easy", bundle: .module)
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                            Spacer()
                            Text("Hard", bundle: .module)
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
                .textCase(nil)
                Section(header: Text("Data", bundle: .module)) {
                    Button(role: .destructive, action: {
                        resetFlappyBirdHighScore()
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
public class FlappyBirdSettings {
    public var vibrations: Bool = defaults.value(forKey: "flappyBirdVibrations", default: true) {
        didSet { defaults.set(vibrations, forKey: "flappyBirdVibrations") }
    }

    public var difficulty: Int = defaults.value(forKey: "flappyBirdDifficulty", default: 5) {
        didSet { defaults.set(difficulty, forKey: "flappyBirdDifficulty") }
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
