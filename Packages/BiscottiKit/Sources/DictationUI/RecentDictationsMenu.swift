import AppKit
import Dictation
import SwiftUI

/// The "Recent Dictations" submenu of the menu bar: the last dictations with their time,
/// and a click copies one, for text that was not pasted. Menu-compatible content only.
public struct RecentDictationsMenu: View {
    let controller: DictationController
    /// Opens the main window's Dictations page, which lists them all.
    let onShowAll: (@MainActor () -> Void)?

    public init(controller: DictationController, onShowAll: (@MainActor () -> Void)? = nil) {
        self.controller = controller
        self.onShowAll = onShowAll
    }

    public var body: some View {
        let entries = controller.history.entries
        if controller.settings.isEnabled, !entries.isEmpty {
            Menu("Recent Dictations") {
                Text("Click a dictation to copy it")
                ForEach(entries) { entry in
                    Button(entry.menuTitle()) {
                        Self.copy(entry.text)
                    }
                }
                Divider()
                if let onShowAll {
                    Button("Show All Dictations\u{2026}") {
                        onShowAll()
                    }
                }
                Button("Clear Recent Dictations") {
                    controller.history.clear()
                }
            }
        }
    }

    private static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
