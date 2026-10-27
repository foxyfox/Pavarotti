import AppKit
import Dictation
import SwiftUI

/// The "Transcribe Audio File" window: drop, paste or choose a file, then copy or save the
/// transcript as Markdown. One window for the app's lifetime, created on first use, so a
/// result survives closing it. The main window's Transcribe File page shows the same
/// transcription.
@MainActor
public final class FileTranscriptionWindow {
    private static var shared: FileTranscriptionWindow?

    private let session: FileTranscriptionSession
    private let window: FileDropWindow

    /// Shows the window, creating it on first use.
    public static func show(controller: DictationController) {
        let instance = shared ?? FileTranscriptionWindow(controller: controller)
        shared = instance
        instance.show()
    }

    private init(controller: DictationController) {
        let session = SharedFileTranscription.session(for: controller)
        let window = FileDropWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcribe Audio File"
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: FileTranscriptionView(session: session))
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 560, height: 460))
        window.onPasteFile = { [weak session] url in
            session?.transcribe(url)
        }
        window.center()
        self.session = session
        self.window = window
    }

    private func show() {
        // Like the main window: in the Dock and the app switcher while it is open. The app
        // goes back to the menu bar when its last window closes.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// Takes ⌘V of a file copied in Finder. It never becomes the main window, so the app's
/// main-window handling (Dock icon, "Open Pavarotti") leaves it alone.
final class FileDropWindow: NSWindow {
    var onPasteFile: (@MainActor (URL) -> Void)?

    override var canBecomeMain: Bool {
        false
    }

    @objc func paste(_: Any?) {
        guard let url = FilePasteboard.fileURL() else {
            NSSound.beep()
            return
        }
        onPasteFile?(url)
    }
}

/// Reads a file copied in Finder from the clipboard.
enum FilePasteboard {
    static func fileURL(from pasteboard: NSPasteboard = .general) -> URL? {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        return urls?.first
    }
}

/// The menu bar item that opens the file transcription window.
public struct FileTranscriptionMenuItem: View {
    let controller: DictationController

    public init(controller: DictationController) {
        self.controller = controller
    }

    public var body: some View {
        Button("Transcribe Audio File\u{2026}") {
            FileTranscriptionWindow.show(controller: controller)
        }
    }
}
