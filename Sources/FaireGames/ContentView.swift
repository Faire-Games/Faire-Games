// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import AppFairUI
import FaireGamesModel
import BlockBlast
import Tetris
import FlappyBird
import Breakout
import Sudoku
import TwentyFortyEight
import Drop7

let gamePreviewIconSpan = 120.0

struct ContentView: View {
    @State var gamePreferences = GamePreferences()
    @State var showSettings = false
    @State var confirmResetBlockBlast = false
    @State var confirmResetTetris = false
    @State var confirmResetFlappyBird = false
    @State var confirmResetBreakout = false
    @State var confirmResetSudoku = false
    @State var confirmResetTwentyFortyEight = false
    @State var confirmResetDrop7 = false

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
                                Text("Block Blast!", bundle: .module)
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
                                Label { Text("Reset High Score", bundle: .module) } icon: { Image("restart_alt", bundle: .module) }
                            }
                        }
                        .confirmationDialog(Text("Reset Block Blast High Score?", bundle: .module), isPresented: $confirmResetBlockBlast, titleVisibility: .visible) {
                            Button(role: ButtonRole.destructive, action: {
                                resetBlockBlastHighScore()
                            }) { Text("Reset", bundle: .module) }
                        } message: {
                            Text("This will permanently reset your Block Blast high score to zero.", bundle: .module)
                        }

                        NavigationLink(destination: TetrisContainerView()) {
                            VStack(spacing: 10) {
                                TetrisPreviewIcon()
                                    .frame(width: gamePreviewIconSpan, height: gamePreviewIconSpan)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                Text("Sirtet", bundle: .module) // ("Tetris")
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
                                Label { Text("Reset High Score", bundle: .module) } icon: { Image("restart_alt", bundle: .module) }
                            }
                        }
                        .confirmationDialog(Text("Reset Sirtet High Score?", bundle: .module), isPresented: $confirmResetTetris, titleVisibility: .visible) {
                            Button(role: ButtonRole.destructive, action: {
                                resetTetrisHighScore()
                            }) { Text("Reset", bundle: .module) }
                        } message: {
                            Text("This will permanently reset your Sirtet high score to zero.", bundle: .module)
                        }

                        NavigationLink(destination: FlappyBirdContainerView()) {
                            VStack(spacing: 10) {
                                FlappyBirdPreviewIcon()
                                    .frame(width: gamePreviewIconSpan, height: gamePreviewIconSpan)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                Text("Flappy Bird", bundle: .module)
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
                                Label { Text("Reset High Score", bundle: .module) } icon: { Image("restart_alt", bundle: .module) }
                            }
                        }
                        .confirmationDialog(Text("Reset Flappy Bird High Score?", bundle: .module), isPresented: $confirmResetFlappyBird, titleVisibility: .visible) {
                            Button(role: ButtonRole.destructive, action: {
                                resetFlappyBirdHighScore()
                            }) { Text("Reset", bundle: .module) }
                        } message: {
                            Text("This will permanently reset your Flappy Bird high score to zero.", bundle: .module)
                        }

                        NavigationLink(destination: BreakoutContainerView()) {
                            VStack(spacing: 10) {
                                BreakoutPreviewIcon()
                                    .frame(width: gamePreviewIconSpan, height: gamePreviewIconSpan)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                Text("Breakout", bundle: .module)
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
                                Label { Text("Reset High Score", bundle: .module) } icon: { Image("restart_alt", bundle: .module) }
                            }
                        }
                        .confirmationDialog(Text("Reset Breakout High Score?", bundle: .module), isPresented: $confirmResetBreakout, titleVisibility: .visible) {
                            Button(role: ButtonRole.destructive, action: {
                                resetBreakoutHighScore()
                            }) { Text("Reset", bundle: .module) }
                        } message: {
                            Text("This will permanently reset your Breakout high score to zero.", bundle: .module)
                        }

                        NavigationLink(destination: SudokuContainerView()) {
                            VStack(spacing: 10) {
                                SudokuPreviewIcon()
                                    .frame(width: gamePreviewIconSpan, height: gamePreviewIconSpan)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                Text("Sudoku", bundle: .module)
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
                                Label { Text("Reset Records", bundle: .module) } icon: { Image("restart_alt", bundle: .module) }
                            }
                        }
                        .confirmationDialog(Text("Reset Sudoku Records?", bundle: .module), isPresented: $confirmResetSudoku, titleVisibility: .visible) {
                            Button(role: ButtonRole.destructive, action: {
                                resetSudokuRecords()
                            }) { Text("Reset", bundle: .module) }
                        } message: {
                            Text("This will permanently reset your Sudoku best times and puzzle counts.", bundle: .module)
                        }

                        NavigationLink(destination: TwentyFortyEightContainerView()) {
                            VStack(spacing: 10) {
                                TwentyFortyEightPreviewIcon()
                                    .frame(width: gamePreviewIconSpan, height: gamePreviewIconSpan)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                Text("2048", bundle: .module)
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
                                Label { Text("Reset High Score", bundle: .module) } icon: { Image("restart_alt", bundle: .module) }
                            }
                        }
                        .confirmationDialog(Text("Reset 2048 High Score?", bundle: .module), isPresented: $confirmResetTwentyFortyEight, titleVisibility: .visible) {
                            Button(role: ButtonRole.destructive, action: {
                                resetTwentyFortyEightHighScore()
                            }) { Text("Reset", bundle: .module) }
                        } message: {
                            Text("This will permanently reset your 2048 high score to zero.", bundle: .module)
                        }

                        NavigationLink(destination: Drop7ContainerView()) {
                            VStack(spacing: 10) {
                                Drop7PreviewIcon()
                                    .frame(width: gamePreviewIconSpan, height: gamePreviewIconSpan)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                Text("Drop 7", bundle: .module)
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
                            Button(role: .destructive, action: { confirmResetDrop7 = true }) {
                                Label { Text("Reset High Score", bundle: .module) } icon: { Image("restart_alt", bundle: .module) }
                            }
                        }
                        .confirmationDialog(Text("Reset Drop 7 High Score?", bundle: .module), isPresented: $confirmResetDrop7, titleVisibility: .visible) {
                            Button(role: ButtonRole.destructive, action: {
                                resetDrop7HighScore()
                            }) { Text("Reset", bundle: .module) }
                        } message: {
                            Text("This will permanently reset your Drop 7 high score to zero.", bundle: .module)
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
            //.navigationTitle(Text("Fair Games", bundle: .module))
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
            Section(header: Text("Data", bundle: .module)) {
                Button(role: .destructive, action: { confirmResetAll = true }) {
                    Text("Reset All Progress", bundle: .module)
                }
                .confirmationDialog(Text("Reset All Progress?", bundle: .module), isPresented: $confirmResetAll, titleVisibility: .visible) {
                    Button(role: ButtonRole.destructive, action: {
                        resetBlockBlastHighScore()
                        resetTetrisHighScore()
                        resetFlappyBirdHighScore()
                        resetBreakoutHighScore()
                        resetSudokuRecords()
                        resetTwentyFortyEightHighScore()
                        resetDrop7HighScore()
                    }) { Text("Reset All", bundle: .module) }
                } message: {
                    Text("This will permanently reset all high scores and game progress to zero.", bundle: .module)
                }
            }
        }
    }
}
