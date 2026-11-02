import Foundation

/// Pavarotti: tells whether a calendar participant and a person the user named are the
/// same human, from their names and the calendar's email address.
public enum PersonNames {
    /// The name a calendar participant shows: its own name, else one read from the email
    /// address ("max.mueller@firma.de" → "Max Mueller"), else the address, else "Unknown".
    public static func displayName(name: String?, email: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isRealName(trimmed) { return trimmed }
        let address = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !address.isEmpty else { return trimmed.isEmpty ? "Unknown" : trimmed }
        return Self.name(fromEmail: address) ?? address
    }

    /// Whether `name` names someone, rather than being empty, "Unknown" or an address.
    public static func isRealName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains("@") && trimmed.caseInsensitiveCompare("Unknown") != .orderedSame
    }

    /// A full name read from an address whose local part is a first and last name, such
    /// as "max.mustermann", "max_mustermann" or "max-otto.mustermann"; `nil` for
    /// addresses like "info@" or "m.mustermann@".
    public static func name(fromEmail email: String) -> String? {
        guard let local = email.split(separator: "@").first, email.contains("@") else { return nil }
        let base = local.split(separator: "+").first.map { String($0) } ?? String(local)
        let parts = base.split(whereSeparator: { ".-_".contains($0) }).map { String($0) }
        guard parts.count >= 2, parts.allSatisfy({ $0.count >= 2 && $0.allSatisfy(\.isLetter) }) else {
            return nil
        }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }

    /// The forms of a full name that compare equal: lowercased, accents dropped, umlauts
    /// spelled both ways ("Müller" as "muller" and "mueller"), hyphens as spaces, and
    /// "Last, First" turned round. Empty for a single word, which is too vague to match.
    public static func matchKeys(_ name: String) -> Set<String> {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRealName(text) else { return [] }
        let commaParts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if commaParts.count == 2, !commaParts[0].isEmpty, !commaParts[1].isEmpty {
            text = "\(commaParts[1]) \(commaParts[0])"
        }
        let lowered = text.lowercased()
        let spelledOut = lowered
            .replacingOccurrences(of: "ä", with: "ae")
            .replacingOccurrences(of: "ö", with: "oe")
            .replacingOccurrences(of: "ü", with: "ue")
            .replacingOccurrences(of: "ß", with: "ss")
        var keys: Set<String> = []
        for variant in [lowered, spelledOut] {
            let folded = variant.folding(options: [.diacriticInsensitive], locale: nil)
            let words = folded.split(whereSeparator: { !$0.isLetter }).map { String($0) }
            if words.count >= 2 {
                keys.insert(words.joined(separator: " "))
            }
        }
        return keys
    }

    /// The match keys of a person: those of their name and of the name in their address.
    public static func matchKeys(name: String, email: String?) -> Set<String> {
        var keys = matchKeys(name)
        if let email, let fromEmail = Self.name(fromEmail: email) {
            keys.formUnion(matchKeys(fromEmail))
        }
        return keys
    }
}
