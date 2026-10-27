import AppKit
import DesignSystem
import Dictation
import SwiftUI

/// Pavarotti: the Dictations page of the main window. The recent dictations, newest first,
/// each with its whole text to select, copy again or remove.
public struct RecentDictationsView: View {
    let controller: DictationController
    /// The dictation copied last, marked "Copied" for a moment.
    @State private var copiedID: DictationHistoryEntry.ID?
    @State private var confirmsClear = false

    public init(controller: DictationController) {
        self.controller = controller
    }

    private var entries: [DictationHistoryEntry] {
        controller.history.entries
    }

    public var body: some View {
        Group {
            if entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.contentBackground.ignoresSafeArea())
        .task(id: copiedID) {
            guard copiedID != nil else { return }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            copiedID = nil
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.spacingSM) {
                header
                ForEach(entries) { entry in
                    DictationRow(
                        entry: entry,
                        isCopied: copiedID == entry.id,
                        onCopy: { copy(entry) },
                        onRemove: { controller.history.remove(entry.id) }
                    )
                }
            }
            .frame(maxWidth: Tokens.contentColumnMaxWidth, alignment: .leading)
            .padding(.vertical, Tokens.homeVerticalPadding)
            .padding(.horizontal, Tokens.homeHorizontalPadding)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text("Dictations")
                    .font(.serifHeadline)
                    .foregroundStyle(.ink)
                Text("Your last \(DictationHistory.limit) dictations, newest first. Copy one to paste it again.")
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
            }
            Spacer()
            Button("Clear All\u{2026}") {
                confirmsClear = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.bottom, Tokens.spacingSM)
        .confirmationDialog("Clear all dictations?", isPresented: $confirmsClear) {
            Button("Clear All", role: .destructive) {
                controller.history.clear()
            }
        } message: {
            Text("Text you already pasted stays where it is.")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("No Dictations Yet")
                    .font(.serifHeadline)
            } icon: {
                Image(systemName: "mic")
            }
        } description: {
            if controller.settings.isEnabled {
                Text("Press \(controller.settings.shortcut.displayName) and speak. Your dictations show up here.")
            } else {
                Text("Turn on dictation in Settings. Your dictations show up here.")
            }
        }
    }

    private func copy(_ entry: DictationHistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        copiedID = entry.id
    }
}

/// One dictation: when it was made, its whole text, and buttons to copy or remove it.
private struct DictationRow: View {
    let entry: DictationHistoryEntry
    let isCopied: Bool
    let onCopy: () -> Void
    let onRemove: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            HStack {
                Text(Self.dateText(entry.date))
                    .font(Tokens.metadataFont)
                    .foregroundStyle(Tokens.secondaryText)
                Spacer()
                Button(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc", action: onCopy)
                    .buttonStyle(.borderless)
                    .help("Copy to the clipboard")
                Button("Remove", systemImage: "trash", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Remove this dictation")
            }
            Text(entry.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Tokens.spacingMD)
        .background(Tokens.cardFill, in: shape)
        .overlay(shape.strokeBorder(Tokens.cardStroke, lineWidth: 0.5))
    }

    /// "Today, 14:32", "Yesterday, 09:10", or the weekday and date with the time.
    static func dateText(_ date: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) {
            return "Today, \(time)"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday, \(time)"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}
