import AppKit
import DesignSystem
import SwiftUI

// Pavarotti: the language of the app itself, German or English, the system's by default.

/// The language Pavarotti's windows and menus are in. macOS picks it at launch from the
/// app's own `AppleLanguages` preference, falling back to the system's languages, so a
/// change takes effect after a restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case german = "de"
    case english = "en"

    static let preferenceKey = "AppleLanguages"

    var id: Self {
        self
    }

    /// The languages by their own names, as macOS lists them.
    var displayName: LocalizedStringKey {
        switch self {
        case .system: "System Language"
        case .german: "Deutsch"
        case .english: "English"
        }
    }

    /// The choice saved in the app's own preferences (`domain`), not the system's.
    static func saved(in defaults: UserDefaults, domain: String) -> AppLanguage {
        let languages = defaults.persistentDomain(forName: domain)?[preferenceKey] as? [String]
        return languages?.first.flatMap { AppLanguage(rawValue: String($0.prefix(2))) } ?? .system
    }

    /// Saves the choice; the system language removes the app's own preference again.
    func save(in defaults: UserDefaults) {
        if self == .system {
            defaults.removeObject(forKey: Self.preferenceKey)
        } else {
            defaults.set([rawValue], forKey: Self.preferenceKey)
        }
    }
}

extension SettingsView {
    var appLanguageRow: some View {
        AppLanguageRow()
    }
}

/// The language picker, and a restart button once the choice differs from the language
/// the app was started in.
struct AppLanguageRow: View {
    @State private var chosen = AppLanguage.saved(in: .standard, domain: AppLanguageRow.domain)

    /// The choice the app was started with, read once.
    private nonisolated static let atLaunch = AppLanguage.saved(in: .standard, domain: domain)
    private nonisolated static let domain = Bundle.main.bundleIdentifier ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            Picker("App Language", selection: $chosen) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .onChange(of: chosen) { _, language in
                language.save(in: .standard)
            }
            if chosen == Self.atLaunch {
                caption("Menus and windows follow the system language unless you choose one here.")
            } else {
                HStack {
                    caption("Takes effect when Pavarotti starts again.")
                    Spacer()
                    Button("Restart Now") { AppRelauncher.relaunch() }
                        .controlSize(.small)
                }
            }
        }
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Tokens.metadataFont)
            .foregroundStyle(Tokens.secondaryText)
    }
}

/// Quits Pavarotti and opens it again.
enum AppRelauncher {
    /// A shell waits until this process has ended, then opens the app again. It gives up
    /// after 30 seconds, for example when quitting was cancelled, so the app never opens
    /// out of the blue later.
    @MainActor
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        for i in $(seq 150); do kill -0 \(pid) 2>/dev/null || { /usr/bin/open "$0"; exit 0; }; sleep 0.2; done
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, Bundle.main.bundlePath]
        do {
            try process.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }
}
