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
    /// The dictation the AI model is summarizing right now.
    @State private var summarizingID: DictationHistoryEntry.ID?
    /// Why the last summary failed, for the alert.
    @State private var summaryError: String?
    /// The dictation whose summary was copied last, marked for a moment.
    @State private var summarizedID: DictationHistoryEntry.ID?

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
        .task(id: summarizedID) {
            guard summarizedID != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled {
                summarizedID = nil
            }
        }
        .task(id: copiedID) {
            guard copiedID != nil else { return }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            copiedID = nil
        }
        .alert(
            "Could not summarize",
            isPresented: Binding(get: { summaryError != nil }, set: { if !$0 { summaryError = nil } })
        ) {
            Button("OK") { summaryError = nil }
        } message: {
            Text(verbatim: summaryError ?? "")
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
                        summary: summaryState(of: entry),
                        onCopy: { copy(entry) },
                        onSummarize: { summarize(entry) },
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
        put(entry.text)
        copiedID = entry.id
    }

    private func put(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func summaryState(of entry: DictationHistoryEntry) -> DictationRow.SummaryState {
        if !controller.canStructure { return .unavailable }
        if summarizingID == entry.id { return .running }
        return summarizedID == entry.id ? .copied : .ready
    }

    /// Structures the dictation with the AI model and copies the note to the clipboard.
    private func summarize(_ entry: DictationHistoryEntry) {
        guard summarizingID == nil else { return }
        summarizingID = entry.id
        Task {
            defer { summarizingID = nil }
            do {
                let note = try await controller.structuredText(for: entry.text)
                put(note)
                summarizedID = entry.id
            } catch {
                summaryError = error.localizedDescription
            }
        }
    }
}

/// One dictation: when it was made, its whole text, and buttons to copy or remove it.
private struct DictationRow: View {
    /// What the Summarize button shows.
    enum SummaryState {
        /// No AI model is wired up: no button.
        case unavailable
        case ready
        case running
        case copied
    }

    let entry: DictationHistoryEntry
    let isCopied: Bool
    let summary: SummaryState
    let onCopy: () -> Void
    let onSummarize: () -> Void
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
                summarizeButton
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

    @ViewBuilder
    private var summarizeButton: some View {
        switch summary {
        case .unavailable:
            EmptyView()
        case .running:
            HStack(spacing: Tokens.spacingXS) {
                ProgressView()
                    .controlSize(.small)
                Text("Summarizing\u{2026}")
            }
            .foregroundStyle(Tokens.secondaryText)
        case .ready, .copied:
            Button(
                summary == .copied ? "Summary Copied" : "Summarize",
                systemImage: summary == .copied ? "checkmark" : "sparkles",
                action: onSummarize
            )
            .buttonStyle(.borderless)
            .help("Structure this dictation with the AI model and copy the result to the clipboard")
        }
    }

    /// "Today, 14:32", "Yesterday, 09:10", or the weekday and date with the time.
    static func dateText(_ date: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) {
            return String(localized: "Today, \(time)")
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "Yesterday, \(time)")
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}
