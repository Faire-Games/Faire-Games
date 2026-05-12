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

// MARK: - FaireGameInfo

/// A self-contained description of a game tile on the home grid: stable
/// identifier, localized strings, view factories, and the reset action. All
/// per-game knowledge lives here so `ContentView` can render any game by
/// iterating over `FaireGameInfo` instances without per-game switches.
struct FaireGameInfo: Identifiable, Hashable {
    let id: String
    let title: @MainActor () -> Text
    let previewIcon: @MainActor () -> AnyView
    let destination: @MainActor () -> AnyView
    let resetMenuLabel: @MainActor () -> Text
    let resetDialogTitle: @MainActor () -> Text
    let resetDialogMessage: @MainActor () -> Text
    let reset: @MainActor () -> Void

    static func == (lhs: FaireGameInfo, rhs: FaireGameInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension FaireGameInfo {
    static let twentyFortyEight = FaireGameInfo(
        id: "twentyFortyEight",
        title: { Text("2048", bundle: .module) },
        previewIcon: { AnyView(TwentyFortyEightPreviewIcon()) },
        destination: { AnyView(TwentyFortyEightContainerView()) },
        resetMenuLabel: { Text("Reset High Score", bundle: .module) },
        resetDialogTitle: { Text("Reset 2048 High Score?", bundle: .module) },
        resetDialogMessage: { Text("This will permanently reset your 2048 high score to zero.", bundle: .module) },
        reset: { resetTwentyFortyEightHighScore() }
    )

    static let blockBlast = FaireGameInfo(
        id: "blockBlast",
        title: { Text("Block Blast!", bundle: .module) },
        previewIcon: { AnyView(BlockBlastPreviewIcon()) },
        destination: { AnyView(BlockBlastContainerView()) },
        resetMenuLabel: { Text("Reset High Score", bundle: .module) },
        resetDialogTitle: { Text("Reset Block Blast High Score?", bundle: .module) },
        resetDialogMessage: { Text("This will permanently reset your Block Blast high score to zero.", bundle: .module) },
        reset: { resetBlockBlastHighScore() }
    )

    static let drop7 = FaireGameInfo(
        id: "drop7",
        title: { Text("Drop 7", bundle: .module) },
        previewIcon: { AnyView(Drop7PreviewIcon()) },
        destination: { AnyView(Drop7ContainerView()) },
        resetMenuLabel: { Text("Reset High Score", bundle: .module) },
        resetDialogTitle: { Text("Reset Drop 7 High Score?", bundle: .module) },
        resetDialogMessage: { Text("This will permanently reset your Drop 7 high score to zero.", bundle: .module) },
        reset: { resetDrop7HighScore() }
    )

    static let sudoku = FaireGameInfo(
        id: "sudoku",
        title: { Text("Sudoku", bundle: .module) },
        previewIcon: { AnyView(SudokuPreviewIcon()) },
        destination: { AnyView(SudokuContainerView()) },
        resetMenuLabel: { Text("Reset Records", bundle: .module) },
        resetDialogTitle: { Text("Reset Sudoku Records?", bundle: .module) },
        resetDialogMessage: { Text("This will permanently reset your Sudoku best times and puzzle counts.", bundle: .module) },
        reset: { resetSudokuRecords() }
    )

    static let sirtet = FaireGameInfo(
        id: "sirtet",
        title: { Text("Sirtet", bundle: .module) },
        previewIcon: { AnyView(TetrisPreviewIcon()) },
        destination: { AnyView(TetrisContainerView()) },
        resetMenuLabel: { Text("Reset High Score", bundle: .module) },
        resetDialogTitle: { Text("Reset Sirtet High Score?", bundle: .module) },
        resetDialogMessage: { Text("This will permanently reset your Sirtet high score to zero.", bundle: .module) },
        reset: { resetTetrisHighScore() }
    )

    static let breakout = FaireGameInfo(
        id: "breakout",
        title: { Text("Breakout", bundle: .module) },
        previewIcon: { AnyView(BreakoutPreviewIcon()) },
        destination: { AnyView(BreakoutContainerView()) },
        resetMenuLabel: { Text("Reset High Score", bundle: .module) },
        resetDialogTitle: { Text("Reset Breakout High Score?", bundle: .module) },
        resetDialogMessage: { Text("This will permanently reset your Breakout high score to zero.", bundle: .module) },
        reset: { resetBreakoutHighScore() }
    )

    static let flappyBird = FaireGameInfo(
        id: "flappyBird",
        title: { Text("Flappy Bird", bundle: .module) },
        previewIcon: { AnyView(FlappyBirdPreviewIcon()) },
        destination: { AnyView(FlappyBirdContainerView()) },
        resetMenuLabel: { Text("Reset High Score", bundle: .module) },
        resetDialogTitle: { Text("Reset Flappy Bird High Score?", bundle: .module) },
        resetDialogMessage: { Text("This will permanently reset your Flappy Bird high score to zero.", bundle: .module) },
        reset: { resetFlappyBirdHighScore() }
    )

    /// Canonical default ordering of every shipping game.
    static let allGames: [FaireGameInfo] = [
        .twentyFortyEight, .blockBlast, .drop7, .sudoku, .sirtet, .breakout, .flappyBird,
    ]

    static func lookup(id: String) -> FaireGameInfo? {
        allGames.first(where: { $0.id == id })
    }
}

// MARK: - PreferenceKey for tile frame tracking

/// Reports each tile's laid-out frame, keyed by `FaireGameInfo.id`. Used by
/// the drag-to-reorder hit-test and to size the floating drag overlay.
private struct TileFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        for (k, v) in nextValue() {
            value[k] = v
        }
    }
}

// MARK: - ContentView

struct ContentView: View {
    @State var gamePreferences = GamePreferences()
    @State var showSettings = false

    /// Whether the home grid is in rearrange mode. Entered via long-press on
    /// a tile, exited via the toolbar Done button.
    @State private var isReordering: Bool = false
    /// Identifier of the tile currently being dragged, if any.
    @State private var draggedID: String? = nil
    /// Current finger position in global coordinates.
    @State private var dragLocation: CGPoint = .zero
    /// Where in the dragged tile (relative to its origin) the finger first
    /// touched, in global coordinates. The drag overlay subtracts this so the
    /// tile stays glued to the finger's original grab point — even after the
    /// grid reflows underneath.
    @State private var dragTouchOffsetInTile: CGPoint = .zero
    /// Most recent measured frame of each tile, in global coordinates.
    @State private var tileFrames: [String: CGRect] = [:]
    /// The game whose reset confirmation dialog is currently being prompted.
    @State private var pendingReset: FaireGameInfo? = nil

    /// Resolved order: stored preference (filtered to known IDs) plus any
    /// games not yet present, falling back to the canonical default.
    private var orderedGames: [FaireGameInfo] {
        let stored = gamePreferences.gameOrder.compactMap { FaireGameInfo.lookup(id: $0) }
        let storedIDs = Set(stored.map { $0.id })
        let missing = FaireGameInfo.allGames.filter { !storedIDs.contains($0.id) }
        let combined = stored + missing
        return combined.isEmpty ? FaireGameInfo.allGames : combined
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: gamePreviewIconSpan + 30.0), spacing: 16)], spacing: 16) {
                        ForEach(orderedGames) { info in
                            tileWrapper(for: info)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 20)
            }
            .scrollDisabled(isReordering)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.1, green: 0.1, blue: 0.2), Color(red: 0.05, green: 0.05, blue: 0.15)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .onPreferenceChange(TileFramePreferenceKey.self) { frames in
                tileFrames = frames
            }
            .overlay(alignment: .topLeading) {
                draggedTileOverlay
            }
#if !os(macOS)
            .toolbarColorScheme(.dark, for: .navigationBar)
#endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    if isReordering {
                        Button(action: {
                            withAnimation { isReordering = false }
                        }) {
                            Text("Done", bundle: .module)
                                .foregroundStyle(.white)
                        }
                    } else {
                        Button(action: { showSettings = true }) {
                            Image("settings", bundle: .module)
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(gamePreferences: gamePreferences)
                    .presentationDetents([.medium, .large])
            }
            .confirmationDialog(
                pendingReset?.resetDialogTitle() ?? Text(verbatim: ""),
                isPresented: Binding(
                    get: { pendingReset != nil },
                    set: { newValue in if !newValue { pendingReset = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(role: ButtonRole.destructive, action: {
                    pendingReset?.reset()
                    pendingReset = nil
                }) {
                    Text("Reset", bundle: .module)
                }
            } message: {
                pendingReset?.resetDialogMessage() ?? Text(verbatim: "")
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Tile wrapping (NavigationLink vs. drag-to-reorder)

    @ViewBuilder
    private func tileWrapper(for info: FaireGameInfo) -> some View {
        let isDragging = draggedID == info.id
        Group {
            if isReordering {
                // While being dragged, hide the in-grid tile — the floating
                // overlay shows the moving tile instead. The hidden tile
                // still occupies its layout slot so the grid reflow looks
                // natural.
                gameTileContent(for: info)
                    .opacity(isDragging ? 0.0 : 1.0)
                    .gesture(reorderDragGesture(for: info))
            } else {
                NavigationLink(destination: info.destination()) {
                    gameTileContent(for: info)
                }
                .buttonStyle(.plain)
                .contextMenu { contextMenuItems(for: info) }
                .onLongPressGesture(minimumDuration: 0.5) {
                    withAnimation { isReordering = true }
                }
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: TileFramePreferenceKey.self,
                        value: [info.id: geo.frame(in: .global)]
                    )
            }
        )
    }

    // MARK: - Floating drag overlay

    /// Mirrors the dragged tile and positions it so the original grab point
    /// stays under the user's finger, independently of how the grid reflows.
    @ViewBuilder
    private var draggedTileOverlay: some View {
        GeometryReader { geo in
            let containerOrigin = geo.frame(in: .global).origin
            if let id = draggedID,
               let info = FaireGameInfo.lookup(id: id),
               let frame = tileFrames[id] {
                let originX = dragLocation.x - dragTouchOffsetInTile.x - containerOrigin.x
                let originY = dragLocation.y - dragTouchOffsetInTile.y - containerOrigin.y
                gameTileContent(for: info)
                    .frame(width: frame.width, height: frame.height)
                    .scaleEffect(1.06)
                    .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: 6)
                    .position(x: originX + frame.width / 2.0, y: originY + frame.height / 2.0)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Reorder drag gesture

    private func reorderDragGesture(for info: FaireGameInfo) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                if draggedID == nil {
                    draggedID = info.id
                    let tileOrigin = tileFrames[info.id]?.origin ?? CGPoint.zero
                    dragTouchOffsetInTile = CGPoint(
                        x: value.startLocation.x - tileOrigin.x,
                        y: value.startLocation.y - tileOrigin.y
                    )
                }
                guard draggedID == info.id else { return }
                dragLocation = value.location
                handleDragMoved(info: info, location: value.location)
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    draggedID = nil
                    dragLocation = CGPoint.zero
                    dragTouchOffsetInTile = CGPoint.zero
                }
            }
    }

    private func handleDragMoved(info: FaireGameInfo, location: CGPoint) {
        guard let targetID = tileFrames.first(where: { $0.key != info.id && $0.value.contains(location) })?.key else {
            return
        }
        var order = orderedGames
        guard let from = order.firstIndex(where: { $0.id == info.id }),
              let to = order.firstIndex(where: { $0.id == targetID }),
              from != to else {
            return
        }
        let item = order.remove(at: from)
        order.insert(item, at: to)
        let newRaw = order.map { $0.id }
        if newRaw != gamePreferences.gameOrder {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                gamePreferences.gameOrder = newRaw
            }
        }
    }

    // MARK: - Tile content + context menu

    @ViewBuilder
    private func gameTileContent(for info: FaireGameInfo) -> some View {
        VStack(spacing: 10) {
            info.previewIcon()
                .frame(width: gamePreviewIconSpan, height: gamePreviewIconSpan)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            info.title()
                .font(.headline)
                .foregroundStyle(Color.white)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.08))
        .cornerRadius(20)
    }

    @ViewBuilder
    private func contextMenuItems(for info: FaireGameInfo) -> some View {
        Button(role: .destructive, action: {
            pendingReset = info
        }) {
            Label { info.resetMenuLabel() } icon: { Image("restart_alt", bundle: .module) }
        }
        Button(action: {
            withAnimation { isReordering = true }
        }) {
            Label { Text("Rearrange", bundle: .module) } icon: { Image("swap_vert", bundle: .module) }
        }
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
                        for info in FaireGameInfo.allGames {
                            info.reset()
                        }
                    }) { Text("Reset All", bundle: .module) }
                } message: {
                    Text("This will permanently reset all high scores and game progress to zero.", bundle: .module)
                }
            }
        }
    }
}
