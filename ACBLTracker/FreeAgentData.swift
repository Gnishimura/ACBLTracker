import Foundation

// Data behind the Free Agents tab: who's rostered (from the league's Google Sheet) and how everyone has scored
// (from every finished box score this season). No UI here.

// MARK: - League sheet

/// The league's public Google Sheet. Weekly roster tabs are named "W1", "W2", ...; "Positions" has league positions.
enum LeagueSheet {
    static let spreadsheetID = "1A-e0RZJ-ccr9vSWwpQzHuR4tlcPMHlxONrbnQJR1oso"

    /// A tab with fewer roster entries than this hasn't been filled in yet. Google also answers an unknown tab name
    /// with the first tab instead of an error, which this catches too.
    static let minimumRosterSize = 50

    static func rows(tab: String, range: String? = nil) async throws -> [[String]] {
        var comps = URLComponents(string: "https://docs.google.com/spreadsheets/d/\(spreadsheetID)/gviz/tq")!
        // headers=0: otherwise Google guesses header rows and glues them into one cell.
        comps.queryItems = [URLQueryItem(name: "tqx", value: "out:csv"), URLQueryItem(name: "sheet", value: tab),
                            URLQueryItem(name: "headers", value: "0")]
        if let range { comps.queryItems?.append(URLQueryItem(name: "range", value: range)) }
        guard let url = comps.url else { throw ClientError.badStatus }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8)
        else { throw ClientError.badStatus }
        return CSV.parse(text)
    }

    /// Every filled cell in columns A and G, where each team's block keeps its names (scores and comments sit in
    /// the other columns). Team names and notes are in there too; RosterMatcher.isPlayerCell sorts them out.
    static func rosterCells(_ rows: [[String]]) -> [String] {
        rows.flatMap { row in
            [0, 6].compactMap { c -> String? in
                guard c < row.count else { return nil }
                let cell = row[c].trimmingCharacters(in: .whitespaces)
                return cell.isEmpty ? nil : cell
            }
        }
    }

    /// League positions by normalized player name, from the Positions tab (column C, "Final Revised ACBL Positions").
    static func positions() async throws -> [String: Position] {
        var out: [String: Position] = [:]
        for row in try await rows(tab: "Positions", range: "A2:C1000") where row.count >= 3 {
            if let pos = Position(rawValue: row[2].trimmingCharacters(in: .whitespaces).uppercased()) {
                out[row[0].normalizedName] = pos
            }
        }
        return out
    }
}

enum CSV {
    /// RFC 4180: quoted fields may hold commas, newlines and doubled quotes.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = text.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? chars.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                row.append(field)
                field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

// MARK: - Matching sheet names to ESPN players

/// The sheet is typed by hand: "G - Garland (LAC)", "F -- Tatum Bos", "C #21 Joel Embiid (phi)", "G - Ant (MIN)",
/// "N. Jokić - DEN - C", "#F 7 Paul Reed (det)", "C - Mamu (Mamukelashvili) (Lal)".
/// This turns each cell into an ESPN player when it can.
struct RosterMatcher {
    enum Result: Equatable {
        case matched(String)
        /// Several players fit (two Wagners on ORL). All of them count as rostered so none shows up by mistake.
        case ambiguous([String])
        case unmatched
    }

    /// Nicknames the league uses, normalized -> ESPN name, normalized.
    static let nicknames: [String: String] = [
        "ant": "anthony edwards", "naw": "nickeil alexander walker", "podz": "brandin podziemski",
        "sga": "shai gilgeous alexander", "kat": "karl anthony towns", "lasmelo": "lamelo ball",
        "spicy p": "pascal siakam", "mamu": "sandro mamukelashvili", "giannis": "giannis antetokounmpo",
        "lebron": "lebron james", "bron": "lebron james", "ad": "anthony davis", "kd": "kevin durant",
        "jjj": "jaren jackson", "wemby": "victor wembanyama", "luka": "luka doncic", "steph": "stephen curry",
        "cp3": "chris paul", "kawhi": "kawhi leonard", "jokic": "nikola jokic", "embiid": "joel embiid",
    ]

    private let players: [DirectoryPlayer]
    private let names: [String]      // normalized, same order as players
    private let teams: Set<String>   // ESPN abbreviations

    init(players: [DirectoryPlayer]) {
        self.players = players
        self.names = players.map { $0.name.normalizedName }
        self.teams = Set(players.map { $0.teamAbbr.uppercased() })
    }

    /// Name and team pulled out of one cell. Extra parentheses ("Mamu (Mamukelashvili)") become alternate names.
    /// `hasPosition` is true when the cell names a G/F/C position.
    static func parse(_ cell: String, teams: Set<String>) -> (names: [String], team: String?, hasPosition: Bool) {
        var s = cell.trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: #"^#\s*"#, with: "", options: .regularExpression)
        var hasPosition = s.range(of: #"^[GFC](?=[\s\-#])"#, options: .regularExpression) != nil
        s = s.replacingOccurrences(of: #"^[GFC](?=[\s\-#])[\s\-]*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^#?\d+\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[+*]+\s*$"#, with: "", options: .regularExpression)

        var team: String? = nil
        // "N. Jokić - DEN - C": team and position as dash-separated pieces.
        var pieces: [String] = []
        for piece in s.components(separatedBy: " - ").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if piece.range(of: #"^[GFC]$"#, options: .regularExpression) != nil {
                hasPosition = true
            } else if team == nil, pieces.count > 0, teams.contains(TeamAlias.canon(piece)) {
                team = TeamAlias.canon(piece)
            } else {
                pieces.append(piece)
            }
        }
        s = pieces.joined(separator: " ")

        var alternates: [String] = []
        let parens = s.matches(of: #/\(([^)]*)\)/#).map { String($0.1).trimmingCharacters(in: .whitespaces) }
        for p in parens {
            if team == nil, p == parens.last, teams.contains(TeamAlias.canon(p)) { team = TeamAlias.canon(p) } else { alternates.append(p) }
        }
        s = s.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        // "Tatum Bos", "Holmgren OKC": a trailing team without parentheses.
        var words = s.split(separator: " ").map(String.init)
        if team == nil, words.count >= 2, let last = words.last, teams.contains(TeamAlias.canon(last)) {
            team = TeamAlias.canon(last)
            words.removeLast()
        }
        // "C.White" -> "C White" so the initial and last name split apart.
        let name = words.joined(separator: " ").replacingOccurrences(of: ".", with: " ")
        return ([name] + alternates, team, hasPosition)
    }

    /// A roster entry names a position or an NBA team. Team names ("BEAUCOUP BUCKETS (Evan)"), notes and
    /// score rows name neither.
    func isPlayerCell(_ cell: String) -> Bool {
        let parsed = Self.parse(cell, teams: teams)
        return parsed.hasPosition || parsed.team != nil
    }

    func match(_ cell: String) -> Result {
        let parsed = Self.parse(cell, teams: teams)
        for name in parsed.names {
            let result = match(name: name, team: parsed.team)
            if result != .unmatched { return result }
        }
        return .unmatched
    }

    private func onTeam(_ i: Int, _ team: String?) -> Bool {
        guard let team else { return true }
        return TeamAlias.canon(players[i].teamAbbr) == team
    }

    private func result(_ idx: [Int]) -> Result {
        if idx.count == 1 { return .matched(players[idx[0]].id) }
        return idx.isEmpty ? .unmatched : .ambiguous(idx.map { players[$0].id })
    }

    private func match(name: String, team: String?) -> Result {
        var key = name.normalizedName
        guard !key.isEmpty else { return .unmatched }
        if let full = Self.nicknames[key] { key = full }
        let all = Array(players.indices)

        // 1. Full name. Two players can share one; the team picks.
        let exact = all.filter { names[$0] == key }
        if exact.count == 1 { return result(exact) }
        if exact.count > 1 {
            let onT = exact.filter { onTeam($0, team) }
            return result(onT.isEmpty ? exact : onT)
        }

        // 2. Last name ("Garland", "C White"), on the team the sheet gives. If nobody fits there he may have been
        //    traded, so take a lone league-wide match.
        let tokens = key.split(separator: " ").map(String.init)
        let last = tokens.last!
        let initial = tokens.count > 1 ? tokens[0].first : nil
        let byLast = all.filter { names[$0].split(separator: " ").last.map(String.init) == last }
        var pool = byLast.filter { onTeam($0, team) }
        if pool.count > 1, let initial {
            let narrowed = pool.filter { names[$0].first == initial }
            if !narrowed.isEmpty { pool = narrowed }
        }
        if !pool.isEmpty, team != nil || pool.count == 1 { return result(pool) }
        if pool.isEmpty, byLast.count == 1 { return result(byLast) }

        // 3. Typos ("Jakob Poetl", "Laarson Mia"): the single closest full name, or last name on the team.
        let fuzzyFull = all.map { ($0, levenshtein(names[$0], key)) }.filter { $0.1 <= 2 }.sorted { $0.1 < $1.1 }
        if let best = fuzzyFull.first, fuzzyFull.count == 1 || fuzzyFull[1].1 > best.1 { return result([best.0]) }
        if team != nil, last.count >= 5 {
            let fuzzyLast = all.filter { onTeam($0, team) }
                .map { ($0, levenshtein(names[$0].split(separator: " ").last.map(String.init) ?? "", last)) }
                .filter { $0.1 <= 2 }.sorted { $0.1 < $1.1 }
            if let best = fuzzyLast.first, fuzzyLast.count == 1 || fuzzyLast[1].1 > best.1 { return result([best.0]) }
        }
        return .unmatched
    }
}

// MARK: - Season box scores

/// Points from every finished regular-season game, saved on the phone so each game is downloaded once.
actor SeasonBoxScores {
    static let shared = SeasonBoxScores()

    struct Game: Codable {
        let date: Date
        /// ESPN athlete id -> points, for players who got on the floor. DNPs are left out.
        let points: [String: Int]
    }

    private struct Saved: Codable {
        var games: [String: Game]   // by ESPN event id
        var doneDays: Set<String>   // ET.dateKey of days whose games are all final and saved
    }

    private var saved = Saved(games: [:], doneDays: [])
    private var loaded = false
    private let fileURL: URL

    init(fileURL: URL = Storage.url("season-boxscores.json")) {
        self.fileURL = fileURL
    }

    var gameCount: Int { saved.games.count }

    /// Downloads whatever finished games aren't saved yet, from `start` through today.
    func refresh(from start: Date) async {
        loadIfNeeded()
        let today = ET.startOfDay(Date())
        var days: [Date] = []
        var d = ET.startOfDay(start)
        while d <= today {
            if !saved.doneDays.contains(ET.dateKey(d)) { days.append(d) }
            d = ET.addDays(1, to: d)
        }

        // Scoreboards first, then the box scores they point to. Six requests at a time.
        let boards = await inBatches(days) { day in (day, try? await ESPNClient.shared.scoreboard(day: day)) }
        var wanted: [GameInfo] = []
        for (_, games) in boards {
            wanted += (games ?? []).filter { $0.state == .final && saved.games[$0.id] == nil }
        }
        let boxes = await inBatches(wanted) { g in (g, try? await ESPNClient.shared.boxscore(eventID: g.id)) }
        for (game, lines) in boxes {
            guard let lines, !lines.isEmpty else { continue }
            let pts = lines.values.filter(\.didPlay).reduce(into: [String: Int]()) { $0[$1.athleteID] = $1.points }
            saved.games[game.id] = Game(date: game.date, points: pts)
        }
        for (day, games) in boards {
            guard let games, day < today else { continue }
            if games.allSatisfy({ $0.state == .final && saved.games[$0.id] != nil }) {
                saved.doneDays.insert(ET.dateKey(day))
            }
        }
        save()
    }

    /// Each player's points in the games he played, newest first.
    func pointsByPlayer() -> [String: [Int]] {
        loadIfNeeded()
        var dated: [String: [(Date, Int)]] = [:]
        for g in saved.games.values {
            for (id, pts) in g.points { dated[id, default: []].append((g.date, pts)) }
        }
        return dated.mapValues { $0.sorted { $0.0 > $1.0 }.map(\.1) }
    }

    private func inBatches<T, R: Sendable>(_ items: [T], _ work: @escaping @Sendable (T) async -> R) async -> [R]
    where T: Sendable {
        var out: [R] = []
        var i = 0
        while i < items.count {
            let chunk = items[i..<min(i + 6, items.count)]
            await withTaskGroup(of: R.self) { group in
                for item in chunk { group.addTask { await work(item) } }
                for await r in group { out.append(r) }
            }
            i += 6
        }
        return out
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = s
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: fileURL, options: .atomic) }
    }
}
