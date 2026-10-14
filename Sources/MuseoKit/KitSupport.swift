import Foundation

// Small helpers the kit keeps to itself, so it needs nothing from the app.

/// Where the kit keeps its own files.
nonisolated enum KitFiles {
    /// `Application Support/MuseoKit/`. Created on demand.
    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MuseoKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Decodes one element of an array, or nil instead of failing the whole array.
nonisolated struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

nonisolated extension String {
    /// System and library text in the house voice: lowercase, no em or en dashes, no
    /// exclamation marks, tidy spaces.
    var kitQuiet: String {
        replacingOccurrences(of: " — ", with: ", ")
            .replacingOccurrences(of: "—", with: ", ")
            .replacingOccurrences(of: " – ", with: ", ")
            .replacingOccurrences(of: "–", with: " ")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: ", ,", with: ",")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

nonisolated extension Date {
    /// "9:41a", "12:05p".
    var kitClock: String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: self)
        let minute = calendar.component(.minute, from: self)
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d%@", h12, minute, hour < 12 ? "a" : "p")
    }

    /// "now", "2m ago", "3h ago", "yesterday", "oct 8".
    var kitRelative: String {
        let now = Date.now
        let seconds = now.timeIntervalSince(self)
        if seconds < 45 { return "now" }
        if seconds < 3600 { return "\(max(1, Int(seconds / 60)))m ago" }
        let calendar = Calendar.current
        if calendar.isDate(self, inSameDayAs: now) { return "\(Int(seconds / 3600))h ago" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(self, inSameDayAs: yesterday) { return "yesterday" }
        let sameYear = calendar.component(.year, from: self) == calendar.component(.year, from: now)
        let style = sameYear
            ? Date.FormatStyle().month(.abbreviated).day()
            : Date.FormatStyle().month(.abbreviated).day().year()
        return formatted(style).replacingOccurrences(of: ",", with: "").lowercased()
    }
}
