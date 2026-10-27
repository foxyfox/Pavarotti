import AppKit
import Dictation
import Observation
import SwiftUI

/// The recording bubble: a small pill at the bottom or top of the screen with the active
/// window that shows a live waveform while dictation listens, then "Transcribing", a
/// failure, or briefly what the dictionary learned. Its size, look and position come from
/// Settings. It never takes focus or clicks, and screen sharing does not show it.
@MainActor
public final class DictationIndicator {
    private let controller: DictationController
    private let meter = DictationLevelMeter()
    private var panel: NSPanel?
    private var lastPhase = DictationController.Phase.idle
    private var meterTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    /// Room for the widest bubble; the panel itself is transparent.
    private static let size = NSSize(width: 480, height: 120)
    /// Distance from the bottom of the screen's visible area.
    private static let bottomMargin: CGFloat = 28
    /// Distance from the top of the screen's visible area, below the menu bar.
    private static let topMargin: CGFloat = 2
    /// How often the waveform reads the microphone level.
    private static let meterInterval = Duration.milliseconds(50)
    /// Time for the bubble to fade out before the panel goes away.
    private static let fadeOut = Duration.milliseconds(250)

    public init(controller: DictationController) {
        self.controller = controller
    }

    /// Starts following the controller.
    public func start() {
        observe()
    }

    private func observe() {
        let (phase, notice) = withObservationTracking {
            (controller.phase, controller.notice)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe()
            }
        }
        follow(phase)
        show(phase != .idle || notice != nil)
    }

    /// Runs the waveform while listening. It keeps its last levels for "Transcribing".
    private func follow(_ phase: DictationController.Phase) {
        defer { lastPhase = phase }
        guard phase != lastPhase else { return }
        if phase == .listening {
            meter.start(at: .now)
            meterTask?.cancel()
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    meter.record(controller.inputLevel, at: .now)
                    try? await Task.sleep(for: Self.meterInterval)
                }
            }
        } else if lastPhase == .listening {
            meterTask?.cancel()
            meterTask = nil
        }
    }

    private func show(_ isVisible: Bool) {
        hideTask?.cancel()
        guard isVisible else {
            // The bubble fades out in SwiftUI first.
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: Self.fadeOut)
                guard !Task.isCancelled else { return }
                self?.panel?.orderOut(nil)
            }
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        guard !panel.isVisible else { return }
        // Placed when it appears, so it does not jump while you talk.
        let screen = FrontmostWindowScreen.ofFrontmostApplication() ?? Self.screenWithMouse() ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let originY = controller.settings.bubble.position == .top
                ? frame.maxY - Self.topMargin - Self.size.height
                : frame.minY + Self.bottomMargin
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: originY))
        }
        panel.orderFrontRegardless()
    }

    private static func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
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
        // Keeps the bubble out of screen sharing and recordings of a meeting.
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: DictationBubbleView(controller: controller, meter: meter))
        return panel
    }
}
