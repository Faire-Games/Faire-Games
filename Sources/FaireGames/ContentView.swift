// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import AppFairUI
import FaireGamesModel
import BlockBlast
import Tetris

struct ContentView: View {
    @AppStorage("name") var welcomeName = "Skipper"
    @AppStorage("appearance") var appearance = ""
    @State var appPreferences = AppPreferences()
    @State var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Choose a Game")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.top, 12)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                        NavigationLink(destination: BlockBlastContainerView()) {
                            VStack(spacing: 10) {
                                BlockBlastIcon()
                                    .frame(width: 120, height: 120)
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

                        NavigationLink(destination: TetrisContainerView()) {
                            VStack(spacing: 10) {
                                TetrisIcon()
                                    .frame(width: 120, height: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                Text("Bazinga!") // ("Tetris")
                                    .font(.headline)
                                    .foregroundStyle(Color.white)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(20)
                        }
                        .buttonStyle(.plain)
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
            .navigationTitle("Faire Games")
            #if !os(macOS)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(.white)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(appearance: $appearance, welcomeName: $welcomeName, appPreferences: appPreferences)
            }
        }
        .environment(appPreferences)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Game Icons

/// Returns the color for a Block Blast icon cell, or nil if empty.
private func blockBlastCellColor(row: Int, col: Int) -> Color? {
    // Bottom two rows filled
    if row == 3 { return Color.red }
    if row == 4 { return Color.blue }
    // Left column stack
    if col == 0 && row >= 0 && row <= 2 { return Color.green }
    // Small orange block
    if row == 2 && (col == 1 || col == 2) { return Color.orange }
    // Purple square
    if (row == 1 || row == 2) && (col == 3 || col == 4) { return Color.purple }
    return nil
}

/// A dynamic Block Blast icon drawn with SwiftUI.
struct BlockBlastIcon: View {
    var body: some View {
        VStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { row in
                HStack(spacing: 1) {
                    ForEach(0..<5, id: \.self) { col in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(blockBlastCellColor(row: row, col: col) ?? Color(red: 0.15, green: 0.15, blue: 0.25))
                    }
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.22))
        )
    }
}

/// Returns the color for a Tetris icon cell, or nil if empty.
private func tetrisCellColor(row: Int, col: Int) -> Color? {
    // Bottom row - full line
    if row == 7 { return Color.cyan }
    // L-piece
    if row == 6 && col >= 0 && col <= 2 { return Color.orange }
    if row == 5 && col == 0 { return Color.orange }
    // S-piece
    if row == 6 && (col == 3 || col == 4) { return Color.green }
    if row == 5 && (col == 4 || col == 5) { return Color.green }
    // T-piece
    if row == 5 && col >= 1 && col <= 3 { return Color.purple }
    if row == 4 && col == 2 { return Color.purple }
    // Falling I-piece
    if col == 3 && row >= 1 && row <= 4 { return Color.cyan }
    return nil
}

/// A dynamic Tetris icon drawn with SwiftUI.
struct TetrisIcon: View {
    var body: some View {
        VStack(spacing: 1) {
            ForEach(0..<8, id: \.self) { row in
                HStack(spacing: 1) {
                    ForEach(0..<6, id: \.self) { col in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(tetrisCellColor(row: row, col: col) ?? Color.clear)
                    }
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.18))
        )
    }
}

struct SettingsView: View {
    @Binding var appearance: String
    @Binding var welcomeName: String
    @Bindable var appPreferences: AppPreferences

    var body: some View {
        NavigationStack {
            Form {
                Section("Preferences") {
                    TextField("Name", text: $welcomeName)
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }
                Section("Gameplay") {
                    Toggle("Haptic Feedback", isOn: $appPreferences.hapticsEnabled)
                }
            }
            .navigationTitle("Settings")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}
