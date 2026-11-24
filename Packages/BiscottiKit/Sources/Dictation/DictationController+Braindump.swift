import Foundation
import os

// MARK: - Braindump (Pavarotti)

/// Turns a dictation into a structured note with an AI model.
public protocol DictationTextStructuring: Sendable {
    /// The structured Markdown for `text`.
    func structure(_ text: String) async throws -> String
}

/// Why a braindump could not be structured.
public enum BraindumpError: Error, Equatable, LocalizedError {
    /// No local model is downloaded and no AI provider is set up.
    case noModel

    public var errorDescription: String? {
        switch self {
        case .noModel:
            String(localized: "Download an AI model under AI Enhancements or set up an AI provider.")
        }
    }
}

/// The time after the shortcut ended a dictation in which a second press asks for a braindump.
struct BraindumpWindow {
    let session: Int
    let deadline: TimeInterval
}

/// The prompt that turns a spoken braindump into a structured note.
public enum Braindump {
    public static let systemPrompt = """
    You turn a spoken braindump into a clean, structured note in Markdown.

    Rules:
    - Write in the language of the dictation. Never translate: German stays German, \
    English stays English, a mix stays a mix.
    - Keep every idea, fact, name, number, date and to-do that was said. Add nothing \
    that was not said: no introduction, no conclusion, no advice, no comments.
    - Drop filler words, repetitions and false starts. When the speaker corrects \
    themselves, keep only the corrected version.
    - Keep the speaker's wording where you can; fix grammar and punctuation.
    - Group what belongs together. Use short "## " headings only when there are several \
    distinct topics. Use "- " bullet lists for ideas and points. Collect things the \
    speaker wants to do in their own list.
    - A short dictation gets a few bullets or one tidy paragraph, without headings.
    - Answer with the note only: no preamble, no code fence.
    """

    /// The user turn that carries the dictation.
    public static func userPrompt(for text: String) -> String {
        "Structure this dictation:\n\n\(text)"
    }

    /// The model's answer without surrounding whitespace or a Markdown code fence.
    public static func cleaned(_ answer: String) -> String {
        var lines = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("```"), lines.count > 1,
           lines.last?.trimmingCharacters(in: .whitespaces) == "```"
        {
            lines.removeFirst()
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension DictationController {
    /// How soon after the press that ended a dictation a second press makes it a
    /// braindump (seconds).
    static let braindumpWindowLength = 0.4

    private static let braindumpLogger = Logger(subsystem: "de.foxagon.pavarotti", category: "Braindump")

    /// Stops the dictation the shortcut ended; a second press soon after makes it a braindump.
    func stopFromShortcut() {
        stop()
        guard phase == .transcribing, settings.structuresOnDoublePress, structurer != nil else { return }
        braindumpWindow = BraindumpWindow(session: session, deadline: now() + Self.braindumpWindowLength)
    }

    /// Forgets the braindump state of the previous dictation.
    func resetBraindump() {
        isBraindump = false
        braindumpWindow = nil
    }

    /// Takes a press within the window as the second press of a double press.
    /// - Returns: Whether the event was used up, so the gesture must not see it.
    func catchesBraindumpPress(_ event: ShortcutEvent) -> Bool {
        guard event == .pressed, let window = braindumpWindow else { return false }
        braindumpWindow = nil
        guard window.session == session, phase == .transcribing, now() <= window.deadline else { return false }
        isBraindump = true
        return true
    }

    /// The text to paste: `text` as spoken, or structured when the dictation became a
    /// braindump. Waits for the rest of the double-press window first. When structuring
    /// fails, the spoken text is pasted and a notice says why.
    func braindumpText(from text: String, session started: Int) async -> String {
        await waitForBraindumpWindow(session: started)
        guard isBraindump, started == session, let structurer else { return text }
        do {
            let structured = try await Braindump.cleaned(structurer.structure(text))
            return structured.isEmpty ? text : structured
        } catch {
            guard !(error is CancellationError), started == session else { return text }
            Self.braindumpLogger.error("Braindump failed: \(error.localizedDescription, privacy: .public)")
            showNotice(String(localized: "Not structured: \(error.localizedDescription) The text was pasted as spoken."))
            return text
        }
    }

    private func waitForBraindumpWindow(session started: Int) async {
        guard !isBraindump, let window = braindumpWindow, window.session == started else { return }
        let remaining = window.deadline - now()
        guard remaining > 0 else { return }
        try? await Task.sleep(for: .seconds(remaining))
    }
}

public extension DictationController {
    /// Whether an AI model can structure dictations, for the Summarize buttons.
    var canStructure: Bool {
        structurer != nil
    }

    /// `text` structured into a note, like a braindump, for Recent Dictations.
    /// - Throws: ``BraindumpError/noModel`` without a structurer, or the model's error.
    func structuredText(for text: String) async throws -> String {
        guard let structurer else { throw BraindumpError.noModel }
        let structured = try await Braindump.cleaned(structurer.structure(text))
        return structured.isEmpty ? text : structured
    }
}
