import AppKit
import Dictation
import Observation
import SwiftUI

/// A small floating pill at the bottom of the screen that shows when dictation is
/// listening, transcribing or failed, and briefly what the dictionary learned. It
/// never takes focus or clicks.
@MainActor
public final class DictationIndicator {
    private let controller: DictationController
    private var panel: NSPanel?

    private static let size = NSSize(width: 420, height: 64)

    public init(controller: DictationController) {
        self.controller = controller
    }

    /// Starts following the controller.
    public func start() {
        observePhase()
    }

    private func observePhase() {
        let isVisible = withObservationTracking {
            controller.phase != .idle || controller.notice != nil
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observePhase()
            }
        }
        show(isVisible)
    }

    private func show(_ isVisible: Bool) {
        guard isVisible else {
            panel?.orderOut(nil)
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 40))
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: DictationIndicatorView(controller: controller))
        return panel
    }
}

/// The pill itself. Reads the phase straight from the controller.
struct DictationIndicatorView: View {
    let controller: DictationController

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var icon: some View {
        switch controller.phase {
        case .listening:
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .idle:
            Image(systemName: "character.book.closed.fill")
                .foregroundStyle(.secondary)
        }
    }

    private var message: String {
        switch controller.phase {
        case .listening: "Listening\u{2026}"
        case .transcribing: "Transcribing\u{2026}"
        case let .failed(text): text
        case .idle: controller.notice ?? ""
        }
    }
}
