import Foundation

/// Pavarotti: file names of meeting notes, as the TypeWhisper fork gave them:
/// "yyyyMMdd HHmm - Title - Notizen.md". Ported from the fork's recording renamer.
public enum MeetingNoteFileName {
    static let maximumBaseNameUTF8Bytes = 150

    /// "yyyyMMdd HHmm - <title> - Notizen" with the start in `timeZone`, or
    /// "yyyyMMdd HHmm - Notizen" when nothing of the title is left for a file name.
    public static func baseName(title: String, start: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd HHmm"
        let prefix = formatter.string(from: start) + " - "
        let safeTitle = trimmingEdges(
            Self.prefix(fileNameSafeTitle(title), fittingUTF8ByteCount: maximumBaseNameUTF8Bytes - prefix.utf8.count)
        )
        return safeTitle.isEmpty ? prefix + "Notizen" : prefix + safeTitle + " - Notizen"
    }

    /// `baseName.md` in `folder`, or "baseName 2.md" and so on when that is taken.
    public static func availableURL(
        in folder: URL,
        baseName: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        var number = 1
        while true {
            let name = number == 1 ? baseName : "\(baseName) \(number)"
            let candidate = folder.appending(path: name + ".md", directoryHint: .notDirectory)
            if !fileExists(candidate.path) {
                return candidate
            }
            number += 1
        }
    }

    /// The title as part of a file name: NFC, without quotes and characters that break
    /// SMB, OneDrive or Obsidian links (`* ? < > | # ^ [ ]`), slashes as "-", a colon as a
    /// dash, " - " as " – " (so the one after the time stays the only one), no control
    /// characters, single spaces, no dots or dashes at either end.
    static func fileNameSafeTitle(_ title: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in title.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar {
            case "\"", "'", "`", "\u{201E}", "\u{201C}", "\u{201D}", "\u{201A}", "\u{2018}", "\u{2019}",
                 "\u{00AB}", "\u{00BB}", "\u{2039}", "\u{203A}", "*", "?", "<", ">", "|", "#", "^", "[", "]":
                continue
            case "/", "\\":
                result.append("-")
            case ":":
                result.append(contentsOf: " \u{2013} ".unicodeScalars)
            default:
                if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                    result.append(" ")
                } else {
                    result.append(scalar)
                }
            }
        }
        let collapsed = String(result)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: " - ", with: " \u{2013} ")
        return trimmingEdges(collapsed)
    }

    /// The longest start of `value` with at most `maximumByteCount` UTF-8 bytes, cut
    /// between characters.
    static func prefix(_ value: String, fittingUTF8ByteCount maximumByteCount: Int) -> String {
        var byteCount = 0
        var result = ""
        for character in value {
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= maximumByteCount else { break }
            result.append(character)
            byteCount += characterByteCount
        }
        return result
    }

    private static func trimmingEdges(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-\u{2013}")))
    }
}
