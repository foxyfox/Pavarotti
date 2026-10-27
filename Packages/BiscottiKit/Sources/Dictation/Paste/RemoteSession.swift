import Foundation

// Pavarotti: recognizes remote desktop clients, ported from Andreas's TypeWhisper fork.
// A remote target gets the slower chord timing, the clipboard sync before the paste
// (RemoteClipboardSync.swift) and a longer pause before the clipboard is restored.

enum RemoteSessionKind: String, Equatable {
    case macScreenSharing
    case windowsRemoteDesktop
    case genericRemote
}

enum RemoteSessionClassifier {
    private static let screenSharingBundleIdentifier = "com.apple.screensharing"
    /// Windows App and the former Microsoft Remote Desktop, e.g. `com.microsoft.rdc.macos`.
    private static let windowsAppBundleIdentifierPrefix = "com.microsoft.rdc"
    private static let genericRemoteBundleIdentifiers: Set<String> = ["com.carriez.rustdesk"]

    /// Bundle identifiers compare case-insensitively. A prefix only matches at a dot, so
    /// `com.microsoft.rdc` covers `com.microsoft.rdc.macos` but not `com.microsoft.rdcx`.
    /// `additionalBundleIdentifiers` count as `.genericRemote`; they come from the hidden
    /// default `remoteInsertionAdditionalBundleIdentifiers`:
    /// `defaults write de.foxagon.pavarotti remoteInsertionAdditionalBundleIdentifiers -array com.example.viewer`
    static func classify(bundleIdentifier: String?, additionalBundleIdentifiers: [String] = []) -> RemoteSessionKind? {
        guard let identifier = normalized(bundleIdentifier) else { return nil }
        if identifier == screenSharingBundleIdentifier {
            return .macScreenSharing
        }
        let prefix = windowsAppBundleIdentifierPrefix
        if identifier == prefix || identifier.hasPrefix(prefix + ".") {
            return .windowsRemoteDesktop
        }
        if genericRemoteBundleIdentifiers.contains(identifier)
            || additionalBundleIdentifiers.contains(where: { normalized($0) == identifier })
        {
            return .genericRemote
        }
        return nil
    }

    static func additionalBundleIdentifiers(from defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: "remoteInsertionAdditionalBundleIdentifiers") ?? []
    }

    private static func normalized(_ bundleIdentifier: String?) -> String? {
        guard let identifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !identifier.isEmpty
        else {
            return nil
        }
        return identifier
    }
}
