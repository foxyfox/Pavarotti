import Foundation

/// An audio input device.
public struct MicrophoneDevice: Codable, Hashable, Identifiable, Sendable {
    /// Core Audio's device UID, which stays the same across restarts and reconnects.
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Whether Pavarotti may record the microphone.
public enum MicrophonePermission: Equatable, Sendable {
    case granted
    /// Not asked yet. The system asks on the first request.
    case undecided
    /// Denied or restricted. Only System Settings can change it.
    case denied
}

/// The microphones of this Mac and the permission to record them.
@MainActor
public protocol MicrophoneProviding: AnyObject {
    var permission: MicrophonePermission { get }
    /// Shows the system prompt when not asked yet. Returns `true` when access is granted.
    func requestPermission() async -> Bool
    /// The input devices connected now.
    func devices() -> [MicrophoneDevice]
    /// The system's default input device.
    func defaultDevice() -> MicrophoneDevice?
}
