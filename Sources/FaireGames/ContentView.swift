// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import AppFairUI
import FaireGamesModel
import BlockBlast
import Tetris
import JewelCrush
import FlappyBird
import Breakout
import Sudoku
import TwentyFortyEight

let gamePreviewIconSpan = 120.0

struct ContentView: View {
    @State var gamePreferences = GamePreferences()
    @State var showSettings = false
    @State var confirmResetBlockBlast = false
    @State var confirmResetTetris = false
    @State var confirmResetJewelCrush = false
    @State var confirmResetFlappyBird = false
    @State var confirmResetBreakout = false
    @State var confirmResetSudoku = false
    @State var confirmResetTwentyFortyEight = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: gamePreviewIconSpan + 30.0), spacing: 16)], spacing: 16) {
                        NavigationLink(destination: BlockBlastContainerView()) {
                            VStack(spacing: 10) {
                                BlockBlastPreviewIcon()
                                    .frame(width: gamePreviewIconSpan, height: gamePreviewIconSpan)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                Text("Block Blast!")
                                    .font(.headline)
                                    .foregroundStyle(Color.white)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(20)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive, action: { confirmResetBlockBlast = true }) {
                                Label("Reset High Score", image: "restart_alt")
                            }
                        }
                        .confirmationDialog("Reset Block Blast High Score?", isPresented: $confirmResetBlockBlast, titleVisibility: .visible) {
                            Button("Reset", role: .destructive) {
                                resetBlockBlastHighScore()
                            }
                        } message: {
                            Text("This will permanently reset your Block Blast high score to zero.")
                        }

                        NavigationLink(destination: TetrisContainerView()) {
                            VStack(spacing: 10) {
                                TetrisPreviewIcon()
                                    .frame(width: gamePreviewIconSpan, height: gamePreviewIconSpan)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                Text("Sirtet") // ("Tetris")
                                    .font(.headline)
                                    .foregroundStyle(Color.white)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(20)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive, action: { confirmResetTetris = true }) {
                                Label("Reset High Score", image: "restart_alt")
                            }
                        }
                        .confirmationDialog("Reset Sirtet High Score?", isPresented: $confirmResetTetris, titleVisibility: .visible) {
                            Button("Reset", role: .destructive) {
                                resetTetrisHighScore()
                            }
                        } message: {
                            Text("This will permanently reset your Sirtet high score to zero.")
                        }

                        NavigationLink(destination: FlappyBirdContainerView()) {
                            VStack(spacing: 10) {
                                FlappyBirdPreviewIcon()
                                    .frame(width: gamePreviewIconSpan, height: gamePreviewIconSpan)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                Text("Flappy Bird")
                                    .font(.headline)
                                    .foregroundStyle(Color.white)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(20)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive, action: { confirmResetFlappyBird = true }) {
                                Label("Reset High Score", image: "restart_alt")
                            }
                        }
                        .confirmationDialog("Reset Flappy Bird High Score?", isPresented: $confirmResetFlappyBird, titleVisibility: .visible) {
                            Button("Reset", role: .destructive) {
                                resetFlappyBirdHighScore()
                            }
                        } message: {
                            Text("This will permanently reset your Flappy Bird high score to zero.")
                        }

                        NavigationLink(destination: BreakoutContainerView()) {
                            VStack(spacing: 10) {
                                BreakoutPreviewIcon()
                                    .frame(width: gamePreviewIconSpan, height: gamePreviewIconSpan)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                Text("Breakout")
                                    .font(.headline)
                                    .foregroundStyle(Color.white)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(20)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive, action: { confirmResetBreakout = true }) {
                                Label("Reset High Score", image: "restart_alt")
                            }
                        }
                        .confirmationDialog("Reset Breakout High Score?", isPresented: $confirmResetBreakout, titleVisibility: .visible) {
                            Button("Reset", role: .destructive) {
                                resetBreakoutHighScore()
                            }
                        } message: {
                            Text("This will permanently reset your Breakout high score to zero.")
                        }

                        NavigationLink(destination: SudokuContainerView()) {
                            VStack(spacing: 10) {
                                SudokuPreviewIcon()
                                    .frame(width: gamePreviewIconSpan, height: gamePreviewIconSpan)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                Text("Sudoku")
                                    .font(.headline)
                                    .foregroundStyle(Color.white)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(20)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive, action: { confirmResetSudoku = true }) {
                                Label("Reset Records", image: "restart_alt")
                            }
                        }
                        .confirmationDialog("Reset Sudoku Records?", isPresented: $confirmResetSudoku, titleVisibility: .visible) {
                            Button("Reset", role: .destructive) {
                                resetSudokuRecords()
                            }
                        } message: {
                            Text("This will permanently reset your Sudoku best times and puzzle counts.")
                        }

                        NavigationLink(destination: TwentyFortyEightContainerView()) {
                            VStack(spacing: 10) {
                                TwentyFortyEightPreviewIcon()
                                    .frame(width: gamePreviewIconSpan, height: gamePreviewIconSpan)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                Text("2048")
                                    .font(.headline)
                                    .foregroundStyle(Color.white)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(20)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive, action: { confirmResetTwentyFortyEight = true }) {
                                Label("Reset High Score", image: "restart_alt")
                            }
                        }
                        .confirmationDialog("Reset 2048 High Score?", isPresented: $confirmResetTwentyFortyEight, titleVisibility: .visible) {
                            Button("Reset", role: .destructive) {
                                resetTwentyFortyEightHighScore()
                            }
                        } message: {
                            Text("This will permanently reset your 2048 high score to zero.")
                        }

                        if gamePreferences.showBetaGames {
                            NavigationLink(destination: JewelCrushContainerView()) {
                                VStack(spacing: 10) {
                                    JewelCrushPreviewIcon()
                                        .frame(width: gamePreviewIconSpan, height: gamePreviewIconSpan)
                                        .clipShape(RoundedRectangle(cornerRadius: 16))
                                    Text("Jewel Crush")
                                        .font(.headline)
                                        .foregroundStyle(Color.white)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(20)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive, action: { confirmResetJewelCrush = true }) {
                                    Label("Reset Level", image: "restart_alt")
                                }
                            }
                            .confirmationDialog("Reset Jewel Crush Level?", isPresented: $confirmResetJewelCrush, titleVisibility: .visible) {
                                Button("Reset", role: .destructive) {
                                    resetJewelCrushProgress()
                                }
                            } message: {
                                Text("This will reset your Jewel Crush progress back to Level 1.")
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 20)
            }
            .background(
                LinearGradient(
                    colors: [Color(red: 0.1, green: 0.1, blue: 0.2), Color(red: 0.05, green: 0.05, blue: 0.15)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            //.navigationTitle("Fair Games")
            #if !os(macOS)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: { showSettings = true }) {
                        Image("settings", bundle: .module)
                            .foregroundStyle(.white)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(gamePreferences: gamePreferences)
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct SettingsView: View {
    @Bindable var gamePreferences: GamePreferences
    @State var confirmResetAll = false

    var body: some View {
        AppFairSettings(bundle: .module) {
            Section("Gameplay") {
                Toggle("Show Experimental Games", isOn: $gamePreferences.showBetaGames)
            }
            Section("Data") {
                Button(role: .destructive, action: { confirmResetAll = true }) {
                    Text("Reset All Progress")
                }
                .confirmationDialog("Reset All Progress?", isPresented: $confirmResetAll, titleVisibility: .visible) {
                    Button("Reset All", role: .destructive) {
                        resetBlockBlastHighScore()
                        resetTetrisHighScore()
                        resetJewelCrushProgress()
                        resetFlappyBirdHighScore()
                        resetBreakoutHighScore()
                        resetSudokuRecords()
                        resetTwentyFortyEightHighScore()
                    }
                } message: {
                    Text("This will permanently reset all high scores and game progress to zero.")
                }
            }
        }
    }
}
