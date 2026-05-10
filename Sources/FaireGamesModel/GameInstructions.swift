// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import Foundation

/// Configuration for a game's "How to Play" instructions.
///
/// Games receive a `GameInstructionsConfig` from the app shell and use it to
/// (1) drive an "Instructions" entry in the pause menu and (2) auto-show
/// instructions the first time the user launches that specific game.
public struct GameInstructionsConfig: Hashable {
    /// Localization key for the markdown body (e.g. "Drop7.instructions").
    public let key: String
    /// Bundle the localization is stored in (typically the app shell module bundle).
    public let bundle: Bundle
    /// UserDefaults key used to remember whether the user has already seen this game's instructions.
    public let firstLaunchKey: String
    /// Localized title shown in the navigation bar of the instructions sheet.
    public let title: String

    public init(key: String, bundle: Bundle, firstLaunchKey: String, title: String) {
        self.key = key
        self.bundle = bundle
        self.firstLaunchKey = firstLaunchKey
        self.title = title
    }

    /// Whether the user has already seen this game's instructions at least once.
    public func hasShownToUser() -> Bool {
        return UserDefaults.standard.bool(forKey: firstLaunchKey)
    }

    /// Mark the instructions as shown so the auto-popup does not fire again.
    public func markShownToUser() {
        UserDefaults.standard.set(true, forKey: firstLaunchKey)
    }

    public static func == (lhs: GameInstructionsConfig, rhs: GameInstructionsConfig) -> Bool {
        return lhs.key == rhs.key && lhs.firstLaunchKey == rhs.firstLaunchKey && lhs.title == rhs.title
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(firstLaunchKey)
        hasher.combine(title)
    }
}

/// A scrollable sheet that renders a localized markdown body for a game's
/// instructions, with a Done button.
public struct GameInstructionsView: View {
    let config: GameInstructionsConfig
    @Environment(\.dismiss) var dismiss

    public init(config: GameInstructionsConfig) {
        self.config = config
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                MarkdownBlocksView(text: localizedMarkdown)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(Text(verbatim: config.title))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: { dismiss() }) {
                        Text("Done")
                    }
                }
            }
        }
    }

    var localizedMarkdown: String {
        // Look up the markdown body in the configured bundle. NSLocalizedString
        // returns the key itself if the lookup fails, which is fine as a fallback.
        return NSLocalizedString(config.key, tableName: nil, bundle: config.bundle, value: config.key, comment: "")
    }
}

// MARK: - Minimal markdown block renderer

/// Parses a markdown string into a small set of block kinds and renders them.
/// Supports `# Heading`, `## Subheading`, `- Bullet`, blank-line paragraph
/// breaks, and inline `**bold**`. Anything else renders as a plain paragraph.
struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]

    init(text: String) {
        self.blocks = MarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<blocks.count, id: \.self) { i in
                renderBlock(blocks[i])
            }
        }
    }

    @ViewBuilder
    func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading1:
            inlineText(block.text)
                .font(.title)
                .fontWeight(.bold)
                .padding(.top, 6)
                .padding(.bottom, 2)
        case .heading2:
            inlineText(block.text)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.top, 4)
        case .paragraph:
            inlineText(block.text)
                .font(.body)
        case .bullet:
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .font(.body)
                    .foregroundStyle(Color.secondary)
                inlineText(block.text)
                    .font(.body)
                }
        case .spacer:
            Color.clear.frame(height: 4)
        }
    }

    /// Render a line of body text. Inline `**bold**` markers are stripped — the
    /// visual hierarchy comes from headings and bullets, which is enough for
    /// instructions and avoids relying on `Text + Text` concatenation that
    /// Skip's Kotlin renderer does not support.
    func inlineText(_ s: String) -> Text {
        return Text(verbatim: s.replacingOccurrences(of: "**", with: ""))
    }
}

enum MarkdownBlockKind {
    case heading1
    case heading2
    case paragraph
    case bullet
    case spacer
}

struct MarkdownBlock {
    var kind: MarkdownBlockKind
    var text: String
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var paragraphLines: [String] = []

        func flushParagraph() {
            if !paragraphLines.isEmpty {
                let joined = paragraphLines.joined(separator: " ")
                blocks.append(MarkdownBlock(kind: .paragraph, text: joined))
                paragraphLines = []
            }
        }

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespaces)
            i += 1

            if trimmed.isEmpty {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .spacer, text: ""))
                continue
            }
            if trimmed.hasPrefix("## ") {
                flushParagraph()
                let body = String(trimmed.dropFirst(3))
                blocks.append(MarkdownBlock(kind: .heading2, text: body))
                continue
            }
            if trimmed.hasPrefix("# ") {
                flushParagraph()
                let body = String(trimmed.dropFirst(2))
                blocks.append(MarkdownBlock(kind: .heading1, text: body))
                continue
            }
            if trimmed.hasPrefix("- ") {
                flushParagraph()
                let body = String(trimmed.dropFirst(2))
                blocks.append(MarkdownBlock(kind: .bullet, text: body))
                continue
            }
            paragraphLines.append(trimmed)
        }
        flushParagraph()
        return blocks
    }
}
