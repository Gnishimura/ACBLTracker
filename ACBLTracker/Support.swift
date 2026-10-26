import Foundation

// MARK: - Eastern-time calendar (ESPN groups NBA games by ET day; the league week runs Tue-Mon)

enum ET {
    static let tz = TimeZone(identifier: "America/New_York")!

    static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    /// Midnight ET of the Tuesday that starts the league week containing `d`.
    static func weekStart(containing d: Date) -> Date {
        let c = cal
        let day = c.startOfDay(for: d)
        let weekday = c.component(.weekday, from: day)   // Sunday = 1, Tuesday = 3
        let delta = (weekday - 3 + 7) % 7
        return c.date(byAdding: .day, value: -delta, to: day) ?? day
    }

    static func startOfDay(_ d: Date) -> Date { cal.startOfDay(for: d) }

    static func addDays(_ n: Int, to d: Date) -> Date {
        cal.date(byAdding: .day, value: n, to: d) ?? d
    }

    static func dateKey(_ d: Date) -> String { format("yyyyMMdd", d) }

    static func format(_ pattern: String, _ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = tz
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: d)
    }
}

enum DateParsing {
    /// ESPN dates look like "2026-10-21T23:30Z" (no seconds); the game log uses "2026-10-24T02:00:00.000+00:00".
    static func parse(_ s: String) -> Date? {
        let patterns = ["yyyy-MM-dd'T'HH:mm'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
                        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX"]
        for p in patterns {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = p
            if let d = f.date(from: s) { return d }
        }
        return ISO8601DateFormatter().date(from: s)
    }

    static func localTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }
}

// MARK: - Names and teams

extension String {
    /// Lowercase, no diacritics/punctuation, no Jr/Sr/II/III suffix. "Alperen Şengün" -> "alperen sengun".
    var normalizedName: String {
        let folded = self.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US")).lowercased()
        let cleaned = folded
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
        let suffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv", "v"]
        let tokens = cleaned.split(separator: " ").map(String.init).filter { !suffixes.contains($0) }
        return tokens.joined(separator: " ")
    }
}

func levenshtein(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var prev = Array(0...b.count)
    for i in 1...a.count {
        var cur = [i] + Array(repeating: 0, count: b.count)
        for j in 1...b.count {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        }
        prev = cur
    }
    return prev[b.count]
}

enum TeamAlias {
    /// Sheet abbreviations -> ESPN abbreviations.
    private static let map = [
        "GSW": "GS", "NYK": "NY", "NOP": "NO", "SAS": "SA",
        "UTH": "UTAH", "UTA": "UTAH", "WAS": "WSH", "PHO": "PHX",
        "PHIL": "PHI", "PORT": "POR", "PDX": "POR", "CHLT": "CHA", "WDC": "WSH",
    ]
    static func canon(_ s: String) -> String {
        let u = s.uppercased()
        return map[u] ?? u
    }
}

// MARK: - Storage

enum Storage {
    static func url(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
}
