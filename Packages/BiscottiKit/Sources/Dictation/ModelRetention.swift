import Foundation

/// How long the speech model stays in memory after it was last used.
///
/// Keeping it loaded makes every dictation fast but holds 0.5 to 2 GB, depending on the
/// model. Unloading after a pause gives that memory back, which helps on Macs with little
/// of it; the first dictation afterwards loads the model again while the user speaks.
public enum ModelRetention: String, Codable, CaseIterable, Identifiable, Sendable {
    case always
    case fiveMinutes
    case fifteenMinutes
    case oneHour

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .always: String(localized: "Always")
        case .fiveMinutes: String(localized: "5 minutes")
        case .fifteenMinutes: String(localized: "15 minutes")
        case .oneHour: String(localized: "1 hour")
        }
    }

    /// How long the model may sit unused before it is unloaded; `nil` keeps it loaded.
    public var idleLimit: Duration? {
        switch self {
        case .always: nil
        case .fiveMinutes: .seconds(5 * 60)
        case .fifteenMinutes: .seconds(15 * 60)
        case .oneHour: .seconds(60 * 60)
        }
    }
}
