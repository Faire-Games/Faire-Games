// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import Observation
import SkipKit

public struct BreakoutContainerView: View {
    @State private var settings = BreakoutSettings()

    public init() { }

    public var body: some View {
        BreakoutGameView()
            .navigationTitle("")
            #if !os(macOS)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .colorScheme(.dark)
            #endif
            .environment(settings)
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

// MARK: - Brick Model

final class BrickData {
    var alive: Bool
    let row: Int
    let col: Int

    init(row: Int, col: Int) {
        self.alive = true
        self.row = row
        self.col = col
    }
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
    var paddleWidth: Double = 72.0

    // Ball
    var ballX: Double = 200.0
    var ballY: Double = 500.0
    var ballDX: Double = 0.0
    var ballDY: Double = 0.0

    // Bricks
    var bricks: [[BrickData]] = []

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
        buildLevel()
        resetBall()
    }

    func startLevel(lvl: Int) {
        level = lvl
        isLevelComplete = false
        // Speed increases each level
        ballSpeed = initialBallSpeed + Double(level - 1) * 25.0
        buildLevel()
        resetBall()
    }

    private func buildLevel() {
        bricks = []
        for r in 0..<brickRows {
            var row: [BrickData] = []
            for c in 0..<brickCols {
                row.append(BrickData(row: r, col: c))
            }
            bricks.append(row)
        }
    }

    func resetBall() {
        isLaunched = false
        ballX = paddleX
        ballY = fieldHeight * (1.0 - paddleBottomFraction) - paddleHeight - ballRadius - 2.0
        ballDX = 0.0
        ballDY = 0.0
    }

    func launch() {
        guard !isLaunched else { return }
        isLaunched = true
        // Slight random angle so it's not always straight up
        let angle = Double.random(in: -0.4...0.4)
        ballDX = ballSpeed * sin(angle)
        ballDY = -ballSpeed * cos(angle)
    }

    func update(dt: Double) {
        guard isLaunched && !isGameOver && !isLevelComplete else { return }

        ballX += ballDX * dt
        ballY += ballDY * dt

        // Wall collisions (left/right)
        if ballX - ballRadius < 0.0 {
            ballX = ballRadius
            ballDX = abs(ballDX)
        } else if ballX + ballRadius > fieldWidth {
            ballX = fieldWidth - ballRadius
            ballDX = -abs(ballDX)
        }

        // Ceiling
        if ballY - ballRadius < 0.0 {
            ballY = ballRadius
            ballDY = abs(ballDY)
        }

        // Paddle collision
        let paddleTop = fieldHeight * (1.0 - paddleBottomFraction) - paddleHeight
        let paddleLeft = paddleX - paddleWidth / 2.0
        let paddleRight = paddleX + paddleWidth / 2.0

        if ballDY > 0.0 && ballY + ballRadius >= paddleTop && ballY + ballRadius <= paddleTop + paddleHeight + 4.0 {
            if ballX >= paddleLeft - ballRadius && ballX <= paddleRight + ballRadius {
                ballY = paddleTop - ballRadius
                // Reflect with angle based on where ball hit the paddle
                let hitPos = (ballX - paddleX) / (paddleWidth / 2.0) // -1 to 1
                let clampedHit = min(max(hitPos, -0.95), 0.95)
                let maxAngle = 1.15 // ~66 degrees max
                let angle = clampedHit * maxAngle
                let speed = currentSpeed()
                ballDX = speed * sin(angle)
                ballDY = -speed * cos(angle)
            }
        }

        // Ball lost (below paddle)
        if ballY - ballRadius > fieldHeight {
            lives -= 1
            if lives <= 0 {
                isGameOver = true
                saveHighScore()
            } else {
                resetBall()
            }
            return
        }

        // Brick collisions
        checkBrickCollisions()

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
        }
    }

    private func checkBrickCollisions() {
        for r in 0..<brickRows {
            for c in 0..<brickCols {
                let brick = bricks[r][c]
                if !brick.alive { continue }

                let bx = brickAreaLeft + Double(c) * (brickWidth + brickSpacing)
                let by = brickTopMargin + Double(r) * (brickHeight + brickSpacing)

                // AABB vs circle collision
                let closestX = min(max(ballX, bx), bx + brickWidth)
                let closestY = min(max(ballY, by), by + brickHeight)
                let dx = ballX - closestX
                let dy = ballY - closestY
                let distSq = dx * dx + dy * dy

                if distSq < ballRadius * ballRadius {
                    brick.alive = false
                    score += rowPoints[r]

                    // Determine reflection axis — which face was hit?
                    let overlapLeft = (ballX + ballRadius) - bx
                    let overlapRight = (bx + brickWidth) - (ballX - ballRadius)
                    let overlapTop = (ballY + ballRadius) - by
                    let overlapBottom = (by + brickHeight) - (ballY - ballRadius)

                    let minOverlapX = min(overlapLeft, overlapRight)
                    let minOverlapY = min(overlapTop, overlapBottom)

                    if minOverlapX < minOverlapY {
                        ballDX = -ballDX
                        // Push out
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
                    return // one brick per frame for cleaner physics
                }
            }
        }
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

        // Rebuild bricks and apply saved alive states
        buildLevel()
        var idx = 0
        for r in 0..<bricks.count {
            for c in 0..<bricks[r].count {
                if idx < state.brickAlive.count {
                    bricks[r][c].alive = state.brickAlive[idx]
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
    @State private var game = BreakoutModel()
    @State private var tickTimer: Timer? = nil
    @State private var lastTick: Double = 0.0
    @State private var showSettings = false
    @State private var showPauseMenu = false
    @State private var debugText: String = "waiting for touch"
    @State private var debugTouchCount: Int = 0
    @State private var dragAnchorX: Double? = nil // paddle X at drag start
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

            VStack(spacing: 0) {
                // Fixed HUD bar — buttons live here, outside the drag area
                hudView
                    .frame(height: 44)

                // Playfield — the drag gesture target
                ZStack {
                    // Background — fills the ZStack so it is hittable
                    Color(red: 0.04, green: 0.04, blue: 0.12)

                    gameFieldView(paddleX: game.paddleX, ballX: game.ballX, ballY: game.ballY)

                    if !game.isLaunched && !game.isGameOver && !game.isLevelComplete {
                        launchPrompt
                    }

                    if game.isLevelComplete {
                        levelCompleteOverlay
                    }

                    if game.isGameOver {
                        gameOverOverlay
                    }

                    if showPauseMenu && !game.isGameOver && !game.isLevelComplete {
                        pauseMenuOverlay
                    }

                    // Debug overlay
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
                            debugText = "drag #\(debugTouchCount) loc=(\(Int(value.location.x)),\(Int(value.location.y))) start=(\(Int(value.startLocation.x)),\(Int(value.startLocation.y))) paddleX=\(Int(game.paddleX)) launched=\(game.isLaunched) over=\(game.isGameOver)"

                            if game.isGameOver || game.isLevelComplete || showPauseMenu { return }

                            // Launch ball on first touch
                            if !game.isLaunched {
                                game.launch()
                                playHaptic(.pick)
                            }

                            // On first touch of a drag, record the anchor
                            if dragAnchorX == nil {
                                dragAnchorX = game.paddleX - value.startLocation.x
                            }

                            // Move paddle relative to the anchor so it never jumps
                            let x = min(max((dragAnchorX ?? 0.0) + value.location.x, game.paddleWidth / 2.0), game.fieldWidth - game.paddleWidth / 2.0)
                            game.paddleX = x
                        }
                        .onEnded { _ in
                            dragAnchorX = nil
                        }
                )
            }
            .background(Color(red: 0.04, green: 0.04, blue: 0.12).ignoresSafeArea())
        }
        .navigationBarBackButtonHidden()
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
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
        }
    }

    private func initField(geo: GeometryProxy) -> Bool {
        game.setup(width: geo.size.width, height: geo.size.height)
        return true
    }

    // MARK: - Game Field

    func gameFieldView(paddleX: Double, ballX: Double, ballY: Double) -> some View {
        ZStack(alignment: .topLeading) {
            // Bricks
            ForEach(0..<brickRows, id: \.self) { r in
                ForEach(0..<brickCols, id: \.self) { c in
                    if game.bricks.count > r && game.bricks[r].count > c && game.bricks[r][c].alive {
                        brickView(row: r, col: c)
                    }
                }
            }

            // Ball
            Circle()
                .fill(Color.white)
                .frame(width: ballRadius * 2.0, height: ballRadius * 2.0)
                .position(x: ballX, y: ballY)

            // Paddle
            paddleShape(atX: paddleX)
        }
    }

    // MARK: - Brick

    func brickView(row: Int, col: Int) -> some View {
        let x = game.brickAreaLeft + Double(col) * (game.brickWidth + brickSpacing)
        let y = brickTopMargin + Double(row) * (brickHeight + brickSpacing)
        let ci = row % rowColors.count
        let base = rowColors[ci]
        let baseColor = Color(red: base.0, green: base.1, blue: base.2)
        let lightColor = Color(red: min(base.0 + 0.18, 1.0), green: min(base.1 + 0.18, 1.0), blue: min(base.2 + 0.18, 1.0))
        let darkColor = Color(red: max(base.0 - 0.15, 0.0), green: max(base.1 - 0.15, 0.0), blue: max(base.2 - 0.15, 0.0))

        return ZStack {
            // Base
            RoundedRectangle(cornerRadius: 3)
                .fill(baseColor)
                .frame(width: game.brickWidth, height: brickHeight)
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
        }
        .position(x: x + game.brickWidth / 2.0, y: y + brickHeight / 2.0)
    }

    // MARK: - Paddle

    func paddleShape(atX px: Double) -> some View {
        let y = game.fieldHeight * (1.0 - paddleBottomFraction) - paddleHeight / 2.0
        return ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.70, green: 0.75, blue: 0.85),
                            Color(red: 0.45, green: 0.50, blue: 0.65)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: game.paddleWidth, height: paddleHeight)
            // Top shine
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.35))
                .frame(width: game.paddleWidth - 6, height: paddleHeight * 0.35)
                .offset(y: -paddleHeight * 0.2)
        }
        .position(x: px, y: y)
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
            Text("TAP TO LAUNCH")
                .font(.headline)
                .fontWeight(.black)
                .foregroundStyle(Color.white)
                .shadow(color: .black.opacity(0.4), radius: 2, x: 1, y: 1)
            Text("DRAG TO MOVE PADDLE")
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
                Text("PAUSED")
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundStyle(Color.white)

                Button(action: {
                    showPauseMenu = false
                    startTimer()
                }) {
                    Text("Resume")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 180, height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(red: 0.2, green: 0.6, blue: 0.3))
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 8)

                Button(action: {
                    showPauseMenu = false
                    showSettings = true
                }) {
                    Text("Settings")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 180, height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(red: 0.35, green: 0.45, blue: 0.65))
                        )
                }
                .buttonStyle(.plain)

                Button(action: {
                    showPauseMenu = false
                    BreakoutModel.clearSavedState()
                    game.newGame()
                    startTimer()
                    playHaptic(.snap)
                }) {
                    Text("New Game")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 180, height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(red: 0.3, green: 0.5, blue: 0.9))
                        )
                }
                .buttonStyle(.plain)

                Button(action: { dismiss() }) {
                    Text("Quit Game")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 180, height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(red: 0.8, green: 0.25, blue: 0.25))
                        )
                }
                .buttonStyle(.plain)
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
                    Text("Score")
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
                    Text("Next Level")
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
                Text("GAME OVER")
                    .font(.largeTitle)
                    .fontWeight(.black)
                    .foregroundStyle(Color.white)

                VStack(spacing: 4) {
                    Text("Score")
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
                        Text("Level")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.6))
                        Text("\(game.level)")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.white)
                    }
                    VStack(spacing: 2) {
                        Text("Best")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.6))
                        Text("\(game.highScore)")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.white)
                    }
                }

                if game.score >= game.highScore && game.score > 0 {
                    Text("New High Score!")
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
                    Text("Play Again")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .padding(.top, 4)

                Button(action: { dismiss() }) {
                    Text("Quit Game")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                ShareLink(
                    item: "I scored \(game.score) (level \(game.level)) in Breakout on Faire Games! Can you beat it?\nhttps://appfair.net",
                    subject: Text("Breakout Score"),
                    message: Text("I scored \(game.score) in Breakout!")
                ) {
                    Label("Share", systemImage: "square.and.arrow.up")
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

        let wasBrickCount = aliveBrickCount()
        game.update(dt: dt)
        let nowBrickCount = aliveBrickCount()

        if nowBrickCount < wasBrickCount {
            playHaptic(.snap)
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
                Section("Breakout") {
                    Toggle("Vibrations", isOn: $settings.vibrations)
                }
                Section("Debug") {
                    Toggle("Debug Information", isOn: $settings.debugInfo)
                }
                Section("Data") {
                    Button(role: .destructive, action: {
                        resetBreakoutHighScore()
                    }) {
                        Text("Reset High Score")
                    }
                }
            }
            .navigationTitle("Settings")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
