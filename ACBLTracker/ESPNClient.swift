import Foundation

// Unofficial, unauthenticated ESPN endpoints (the same ones espn.com uses).
// They can change without notice. All ESPN-specific parsing lives in this file so a break is a one-file fix.

enum GameState: Codable { case scheduled, live, final }

struct GameInfo: Identifiable, Equatable {
    let id: String            // ESPN event id
    let date: Date
    let state: GameState
    /// "Q3 4:12", "Half", "End Q2", "Final", "Final/OT". Empty for games that haven't started.
    let statusText: String
    let homeID: String
    let homeAbbr: String
    let awayID: String
    let awayAbbr: String
    /// Games the league ignores (NBA Cup championship game).
    let excluded: Bool
    /// nil until the game tips off.
    var homeScore: Int? = nil
    var awayScore: Int? = nil
}

struct PlayerLine: Equatable {
    let athleteID: String
    let points: Int
    let didPlay: Bool
    /// Field goals made / attempted. nil when ESPN doesn't give them.
    var fgm: Int? = nil
    var fga: Int? = nil
    var box: BoxStats? = nil
}

/// The rest of a player's box score line (points and field goals live on PlayerLine / GameLine).
struct BoxStats: Codable, Equatable {
    var minutes: String? = nil
    var reb: Int? = nil
    var ast: Int? = nil
    var stl: Int? = nil
    var blk: Int? = nil
    var tov: Int? = nil
    var tpm: Int? = nil
    var tpa: Int? = nil
    var ftm: Int? = nil
    var fta: Int? = nil
    var plusMinus: Int? = nil
}

struct DirectoryTeam: Codable, Hashable {
    let id: String
    let abbr: String
    let name: String
    let logo: String?
    var color: String? = nil      // ESPN's primary team color as hex, e.g. "c8102e"
}

struct DirectoryPlayer: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let teamID: String
    let teamAbbr: String
    let position: String
    let headshot: String?

    var headshotURL: URL? {
        URL(string: headshot ?? "https://a.espncdn.com/i/headshots/nba/players/full/\(id).png")
    }
}

/// One entry on ESPN's injury report.
struct Injury: Equatable {
    let status: String      // "Out", "Day-To-Day"
    let part: String?       // "Knee"
    let detail: String?     // "Sprain"

    /// "Out - Knee sprain", "Day-To-Day - Illness". Just the status if ESPN gives no detail.
    var summary: String {
        var what = ""
        if let part, !part.isEmpty, let detail, !detail.isEmpty, part.lowercased() != detail.lowercased() {
            what = "\(part) \(detail.lowercased())"
        } else if let part, !part.isEmpty {
            what = part
        } else if let detail, !detail.isEmpty {
            what = detail
        }
        if what.isEmpty { return status }
        return status.isEmpty ? what : "\(status) - \(what)"
    }
}

/// One of a player's recent NBA games, from ESPN's player game log.
struct RecentGame: Identifiable, Equatable {
    let id: String
    let date: Date
    let opponent: String      // "vs BOS" / "@ BOS"
    let result: String?       // "W" / "L"
    let points: Int?
    let minutes: String?
    let fg: String?           // "6-19"
    let reb: Int?
    let ast: Int?
}

/// A player's season from ESPN's game log.
struct GameLog: Equatable {
    var games: [RecentGame]       // regular season (and playoffs), newest first
    var preseason: [RecentGame]   // newest first
    var seasonPPG: Double?        // regular season only; nil before his first game
}

/// One team's side of a box score, for the Games tab.
struct TeamBox: Identifiable, Equatable {
    let id: String            // ESPN team id
    let abbr: String
    let name: String
    let players: [BoxPlayer]  // starters first, in ESPN's order
}

struct BoxPlayer: Identifiable, Equatable {
    let id: String            // ESPN athlete id
    let name: String
    let starter: Bool
    let didPlay: Bool
    let minutes: String?
    let points: Int?
    let fgm: Int?
    let fga: Int?
}

/// One Rotowire player note from ESPN's fantasy news feed.
struct PlayerNews: Identifiable, Equatable {
    let id: String
    let published: Date
    let headline: String      // the update itself: "Jokic posted 17 points..."
    let story: String?        // the fantasy take that follows it
}

enum ClientError: Error {
    case badStatus
    case noData
}

actor ESPNClient {
    static let shared = ESPNClient()

    private let base = "https://site.api.espn.com/apis/site/v2/sports/basketball/nba"
    private var gameLogCache: [String: (fetched: Date, log: GameLog)] = [:]
    private var newsCache: [String: (fetched: Date, items: [PlayerNews])] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], type: T.Type) async throws -> T {
        guard var comps = URLComponents(string: base + path) else { throw ClientError.badStatus }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw ClientError.badStatus }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.badStatus
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Scoreboard

    func scoreboard(day: Date) async throws -> [GameInfo] {
        let r: ScoreboardResponse = try await get(
            "/scoreboard", query: ["dates": ET.dateKey(day), "limit": "50"], type: ScoreboardResponse.self
        )
        return (r.events ?? []).compactMap { e -> GameInfo? in
            guard let comp = e.competitions?.first,
                  let date = DateParsing.parse(e.date),
                  let home = comp.competitors?.first(where: { $0.homeAway == "home" }),
                  let away = comp.competitors?.first(where: { $0.homeAway == "away" }),
                  let homeTeam = home.team, let awayTeam = away.team
            else { return nil }

            let statusName = (e.status?.type?.name ?? "").uppercased()
            if statusName.contains("POSTPONED") || statusName.contains("CANCEL") { return nil }

            var state = GameState.scheduled
            switch e.status?.type?.state {
            case "in": state = .live
            case "post": state = .final
            default: state = .scheduled
            }

            let period = e.status?.period ?? 0
            let clock = e.status?.displayClock ?? ""
            func periodLabel(_ p: Int) -> String { p <= 4 ? "Q\(p)" : (p == 5 ? "OT" : "\(p - 4)OT") }
            var statusText = ""
            switch state {
            case .final:
                statusText = period <= 4 ? "Final" : "Final/" + periodLabel(period)
            case .live:
                if statusName.contains("HALFTIME") {
                    statusText = "Half"
                } else if statusName.contains("END_PERIOD") {
                    statusText = "End \(periodLabel(period))"
                } else {
                    statusText = "\(periodLabel(period)) \(clock)"
                }
            case .scheduled:
                statusText = ""
            }

            let notes = (comp.notes ?? []).compactMap { $0.headline }.joined(separator: " ").lowercased()
            let excluded = notes.contains("cup") && (notes.contains("championship") || notes.contains("final"))

            return GameInfo(
                id: e.id, date: date, state: state, statusText: statusText,
                homeID: homeTeam.id, homeAbbr: homeTeam.abbreviation ?? "",
                awayID: awayTeam.id, awayAbbr: awayTeam.abbreviation ?? "",
                excluded: excluded,
                homeScore: state == .scheduled ? nil : home.score.flatMap { Int($0) },
                awayScore: state == .scheduled ? nil : away.score.flatMap { Int($0) }
            )
        }
    }

    // MARK: Box score

    /// Returns lines keyed by ESPN athlete id. Players who are inactive are simply absent.
    func boxscore(eventID: String) async throws -> [String: PlayerLine] {
        let r: SummaryResponse = try await get("/summary", query: ["event": eventID], type: SummaryResponse.self)
        var out: [String: PlayerLine] = [:]
        for team in r.boxscore?.players ?? [] {
            guard let group = team.statistics?.first else { continue }
            let labels = (group.labels ?? []).map { $0.uppercased() }
            let names = group.names ?? []
            let ptsIdx = labels.firstIndex(of: "PTS") ?? names.firstIndex(of: "points")
            let minIdx = labels.firstIndex(of: "MIN") ?? names.firstIndex(of: "minutes")
            // ESPN packs field goals into one "8-17" (made-attempted) column.
            let fgIdx = labels.firstIndex(of: "FG")
                ?? names.firstIndex(of: "fieldGoalsMade-fieldGoalsAttempted")
            let tpIdx = labels.firstIndex(of: "3PT")
                ?? names.firstIndex(of: "threePointFieldGoalsMade-threePointFieldGoalsAttempted")
            let ftIdx = labels.firstIndex(of: "FT")
                ?? names.firstIndex(of: "freeThrowsMade-freeThrowsAttempted")
            let rebIdx = labels.firstIndex(of: "REB") ?? names.firstIndex(of: "rebounds")
            let astIdx = labels.firstIndex(of: "AST") ?? names.firstIndex(of: "assists")
            let stlIdx = labels.firstIndex(of: "STL") ?? names.firstIndex(of: "steals")
            let blkIdx = labels.firstIndex(of: "BLK") ?? names.firstIndex(of: "blocks")
            let toIdx = labels.firstIndex(of: "TO") ?? names.firstIndex(of: "turnovers")
            let pmIdx = labels.firstIndex(of: "+/-") ?? names.firstIndex(of: "plusMinus")
            for a in group.athletes ?? [] {
                guard let id = a.athlete?.id else { continue }
                let stats = a.stats ?? []
                if (a.didNotPlay ?? false) || stats.isEmpty {
                    out[id] = PlayerLine(athleteID: id, points: 0, didPlay: false)
                    continue
                }
                let pts: Int = {
                    guard let i = ptsIdx, i < stats.count else { return 0 }
                    return Int(stats[i]) ?? 0
                }()
                var played = true
                if let i = minIdx, i < stats.count {
                    let digits = stats[i].prefix(while: { $0.isNumber })
                    played = (Int(digits) ?? 0) > 0
                }
                func num(_ i: Int?) -> Int? {
                    guard let i, i < stats.count else { return nil }
                    return Int(stats[i])
                }
                // "8-17" style columns: made-attempted.
                func pair(_ i: Int?) -> (Int?, Int?) {
                    guard let i, i < stats.count else { return (nil, nil) }
                    let p = stats[i].split(separator: "-")
                    guard p.count == 2 else { return (nil, nil) }
                    return (Int(p[0]), Int(p[1]))
                }
                let fg = pair(fgIdx)
                let tp = pair(tpIdx)
                let ft = pair(ftIdx)
                var minutes: String? = nil
                if let i = minIdx, i < stats.count { minutes = stats[i] }
                let box = BoxStats(
                    minutes: minutes, reb: num(rebIdx), ast: num(astIdx), stl: num(stlIdx),
                    blk: num(blkIdx), tov: num(toIdx), tpm: tp.0, tpa: tp.1, ftm: ft.0, fta: ft.1,
                    plusMinus: num(pmIdx)
                )
                out[id] = PlayerLine(athleteID: id, points: pts, didPlay: played, fgm: fg.0, fga: fg.1, box: box)
            }
        }
        return out
    }

    /// Both teams' box scores with player names, for the Games tab. Empty before tip-off.
    func teamBoxes(eventID: String) async throws -> [TeamBox] {
        let r: SummaryResponse = try await get("/summary", query: ["event": eventID], type: SummaryResponse.self)
        return (r.boxscore?.players ?? []).compactMap { team -> TeamBox? in
            guard let teamID = team.team?.id, let group = team.statistics?.first else { return nil }
            let labels = (group.labels ?? []).map { $0.uppercased() }
            let names = group.names ?? []
            let ptsIdx = labels.firstIndex(of: "PTS") ?? names.firstIndex(of: "points")
            let minIdx = labels.firstIndex(of: "MIN") ?? names.firstIndex(of: "minutes")
            let fgIdx = labels.firstIndex(of: "FG") ?? names.firstIndex(of: "fieldGoalsMade-fieldGoalsAttempted")
            let players = (group.athletes ?? []).compactMap { a -> BoxPlayer? in
                guard let id = a.athlete?.id, let name = a.athlete?.displayName else { return nil }
                let stats = a.stats ?? []
                func at(_ i: Int?) -> String? {
                    guard let i, i < stats.count else { return nil }
                    return stats[i]
                }
                let minutes = at(minIdx)
                let played = !(a.didNotPlay ?? false) && !stats.isEmpty
                    && (Int(minutes?.prefix(while: { $0.isNumber }) ?? "") ?? 0) > 0
                let fg = at(fgIdx)?.split(separator: "-")
                return BoxPlayer(
                    id: id, name: name, starter: a.starter ?? false, didPlay: played,
                    minutes: minutes, points: at(ptsIdx).flatMap { Int($0) },
                    fgm: fg?.count == 2 ? Int(fg![0]) : nil, fga: fg?.count == 2 ? Int(fg![1]) : nil
                )
            }
            let abbr = team.team?.abbreviation ?? ""
            return TeamBox(id: teamID, abbr: abbr, name: team.team?.displayName ?? abbr, players: players)
        }
    }

    // MARK: Injuries

    /// League-wide injury report. Keyed by ESPN athlete id, or "name:<normalized name>" when ESPN omits the id.
    func injuries() async throws -> [String: Injury] {
        let r: InjuriesResponse = try await get("/injuries", type: InjuriesResponse.self)
        var out: [String: Injury] = [:]
        for team in r.injuries ?? [] {
            for entry in team.injuries ?? [] {
                var status = entry.status ?? ""
                if status.isEmpty { status = (entry.type?.description ?? "").capitalized }
                if status.lowercased() == "active" { continue }
                let injury = Injury(status: status, part: entry.details?.type, detail: entry.details?.detail)
                if let id = entry.athlete?.id {
                    out[id] = injury
                } else if let name = entry.athlete?.displayName {
                    out["name:" + name.normalizedName] = injury
                }
            }
        }
        return out
    }

    // MARK: Recent games

    /// A player's games this season, newest first, and his season scoring average. Cached for five minutes unless `force`.
    func gameLog(athleteID: String, force: Bool = false) async throws -> GameLog {
        if !force, let hit = gameLogCache[athleteID], Date().timeIntervalSince(hit.fetched) < 300 { return hit.log }
        // ESPN names a season by the year it ends: 2026-27 is 2027. Without this it may return the wrong season.
        let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
        let season = (comps.month ?? 1) >= 9 ? (comps.year ?? 2026) + 1 : (comps.year ?? 2027)
        guard let url = URL(string: "https://site.web.api.espn.com/apis/common/v3/sports/basketball/nba/athletes/\(athleteID)/gamelog?season=\(season)")
        else { throw ClientError.badStatus }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.badStatus
        }
        let r = try JSONDecoder().decode(GameLogResponse.self, from: data)
        let names = r.names ?? []
        let labels = (r.labels ?? []).map { $0.uppercased() }
        func idx(_ name: String, _ label: String) -> Int? { names.firstIndex(of: name) ?? labels.firstIndex(of: label) }
        let ptsI = idx("points", "PTS")
        let minI = idx("minutes", "MIN")
        let fgI = idx("fieldGoalsMade-fieldGoalsAttempted", "FG")
        let rebI = idx("totalRebounds", "REB")
        let astI = idx("assists", "AST")

        // Preseason games are kept apart so they don't count toward the season average.
        var games: [RecentGame] = []
        var preseason: [RecentGame] = []
        var regularPoints: [Int] = []
        var seen = Set<String>()
        for t in r.seasonTypes ?? [] {
            let kind = (t.displayName ?? "").lowercased()
            let isPreseason = kind.contains("preseason")
            for c in t.categories ?? [] {
                for e in c.events ?? [] {
                    guard let eid = e.eventId, !seen.contains(eid),
                          let info = r.events?[eid], let date = DateParsing.parse(info.gameDate ?? "")
                    else { continue }
                    seen.insert(eid)
                    let stats = e.stats ?? []
                    func at(_ i: Int?) -> String? {
                        guard let i, i < stats.count else { return nil }
                        return stats[i]
                    }
                    let game = RecentGame(
                        id: eid, date: date,
                        opponent: "\(info.atVs ?? "vs") \(info.opponent?.abbreviation ?? "")",
                        result: info.gameResult,
                        points: at(ptsI).flatMap { Int($0) },
                        minutes: at(minI),
                        fg: at(fgI),
                        reb: at(rebI).flatMap { Int($0) },
                        ast: at(astI).flatMap { Int($0) }
                    )
                    if isPreseason {
                        preseason.append(game)
                    } else {
                        games.append(game)
                        if kind.contains("regular"), let pts = game.points { regularPoints.append(pts) }
                    }
                }
            }
        }
        games.sort { $0.date > $1.date }
        preseason.sort { $0.date > $1.date }
        let ppg = regularPoints.isEmpty ? nil : Double(regularPoints.reduce(0, +)) / Double(regularPoints.count)
        let log = GameLog(games: games, preseason: preseason, seasonPPG: ppg)
        gameLogCache[athleteID] = (Date(), log)
        return log
    }

    // MARK: News

    /// A player's five latest Rotowire notes from the past 7 days, newest first. Cached for five minutes unless `force`.
    func news(athleteID: String, force: Bool = false) async throws -> [PlayerNews] {
        if !force, let hit = newsCache[athleteID], Date().timeIntervalSince(hit.fetched) < 300 { return hit.items }
        // The feed also carries videos and general articles; only the Rotowire notes are about this player.
        guard let url = URL(string: "https://site.api.espn.com/apis/fantasy/v2/games/fba/news/players?limit=50&playerId=\(athleteID)")
        else { throw ClientError.badStatus }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.badStatus
        }
        let r = try JSONDecoder().decode(NewsResponse.self, from: data)
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        let items = (r.feed ?? []).compactMap { a -> PlayerNews? in
            guard a.type == "Rotowire", let id = a.id, let headline = a.headline, !headline.isEmpty,
                  let date = DateParsing.parse(a.published ?? ""), date >= cutoff
            else { return nil }
            let story = a.story?.trimmingCharacters(in: .whitespacesAndNewlines)
            return PlayerNews(id: String(id), published: date, headline: headline, story: story?.isEmpty == false ? story : nil)
        }
        let latest = Array(items.sorted { $0.published > $1.published }.prefix(5))
        newsCache[athleteID] = (Date(), latest)
        return latest
    }

    // MARK: Teams and rosters

    func teams() async throws -> [DirectoryTeam] {
        let r: TeamsResponse = try await get("/teams", query: ["limit": "40"], type: TeamsResponse.self)
        let wrappers = r.sports?.first?.leagues?.first?.teams ?? []
        let teams = wrappers.map { w -> DirectoryTeam in
            let abbr = w.team.abbreviation ?? ""
            return DirectoryTeam(
                id: w.team.id, abbr: abbr, name: w.team.displayName ?? abbr,
                logo: w.team.logos?.first?.href,
                color: w.team.color
            )
        }
        if teams.isEmpty { throw ClientError.noData }
        return teams
    }

    func roster(team: DirectoryTeam) async throws -> [DirectoryPlayer] {
        let r: RosterResponse = try await get("/teams/\(team.id)/roster", type: RosterResponse.self)
        func flatten(_ list: [RosterAthlete]) -> [RosterAthlete] {
            list.flatMap { a -> [RosterAthlete] in
                if let items = a.items { return flatten(items) }
                return [a]
            }
        }
        return flatten(r.athletes ?? []).compactMap { a -> DirectoryPlayer? in
            guard let id = a.id, let name = a.displayName ?? a.fullName else { return nil }
            return DirectoryPlayer(
                id: id, name: name, teamID: team.id, teamAbbr: team.abbr,
                position: a.position?.abbreviation ?? "G", headshot: a.headshot?.href
            )
        }
    }
}

// MARK: - Wire formats (everything optional so small ESPN changes don't break decoding)

private struct ScoreboardResponse: Decodable {
    let events: [Event]?

    struct Event: Decodable {
        let id: String
        let date: String
        let status: Status?
        let competitions: [Competition]?
    }
    struct Status: Decodable {
        let type: StatusType?
        let period: Int?
        let displayClock: String?
    }
    struct StatusType: Decodable {
        let name: String?
        let state: String?
    }
    struct Competition: Decodable {
        let competitors: [Competitor]?
        let notes: [Note]?
    }
    struct Competitor: Decodable {
        let homeAway: String?
        let team: TeamRef?
        let score: String?
    }
    struct TeamRef: Decodable {
        let id: String
        let abbreviation: String?
    }
    struct Note: Decodable { let headline: String? }
}

private struct SummaryResponse: Decodable {
    let boxscore: Box?

    struct Box: Decodable { let players: [TeamPlayers]? }
    struct TeamPlayers: Decodable {
        let team: Team?
        let statistics: [StatGroup]?
    }
    struct Team: Decodable {
        let id: String?
        let abbreviation: String?
        let displayName: String?
    }
    struct StatGroup: Decodable {
        let names: [String]?
        let labels: [String]?
        let athletes: [AthleteLine]?
    }
    struct AthleteLine: Decodable {
        let athlete: Athlete?
        let stats: [String]?
        let didNotPlay: Bool?
        let starter: Bool?
    }
    struct Athlete: Decodable {
        let id: String?
        let displayName: String?
    }
}

private struct InjuriesResponse: Decodable {
    let injuries: [TeamEntry]?

    struct TeamEntry: Decodable { let injuries: [Entry]? }
    struct Entry: Decodable {
        let status: String?
        let athlete: Athlete?
        let type: TypeRef?
        let details: Details?
    }
    struct Athlete: Decodable {
        let id: String?
        let displayName: String?
    }
    struct TypeRef: Decodable { let description: String? }
    struct Details: Decodable {
        let type: String?
        let detail: String?
    }
}

private struct TeamsResponse: Decodable {
    let sports: [Sport]?

    struct Sport: Decodable { let leagues: [League]? }
    struct League: Decodable { let teams: [Wrapper]? }
    struct Wrapper: Decodable { let team: TeamInfo }
    struct TeamInfo: Decodable {
        let id: String
        let abbreviation: String?
        let displayName: String?
        let logos: [Logo]?
        let color: String?
    }
    struct Logo: Decodable { let href: String? }
}

private struct RosterResponse: Decodable {
    let athletes: [RosterAthlete]?
}

private struct RosterAthlete: Decodable {
    let id: String?
    let displayName: String?
    let fullName: String?
    let headshot: ImageRef?
    let position: PositionRef?
    let items: [RosterAthlete]?

    struct ImageRef: Decodable { let href: String? }
    struct PositionRef: Decodable { let abbreviation: String? }

    enum CodingKeys: String, CodingKey {
        case id, displayName, fullName, headshot, position, items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        displayName = try? c.decodeIfPresent(String.self, forKey: .displayName)
        fullName = try? c.decodeIfPresent(String.self, forKey: .fullName)
        headshot = (try? c.decodeIfPresent(ImageRef.self, forKey: .headshot)) ?? nil
        // In grouped rosters "position" is a plain string; in flat ones it's an object. Tolerate both.
        position = (try? c.decodeIfPresent(PositionRef.self, forKey: .position)) ?? nil
        items = (try? c.decodeIfPresent([RosterAthlete].self, forKey: .items)) ?? nil
    }
}

private struct GameLogResponse: Decodable {
    let names: [String]?
    let labels: [String]?
    let events: [String: EventInfo]?
    let seasonTypes: [SeasonType]?

    struct EventInfo: Decodable {
        let atVs: String?
        let gameDate: String?
        let gameResult: String?
        let opponent: Opponent?
    }
    struct Opponent: Decodable { let abbreviation: String? }
    struct SeasonType: Decodable {
        let displayName: String?
        let categories: [Category]?
    }
    struct Category: Decodable { let events: [StatEvent]? }
    struct StatEvent: Decodable {
        let eventId: String?
        let stats: [String]?
    }
}

private struct NewsResponse: Decodable {
    let feed: [Item]?

    struct Item: Decodable {
        let id: Int?
        let type: String?
        let headline: String?
        let story: String?
        let published: String?
    }
}
