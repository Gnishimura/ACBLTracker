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
}

struct PlayerLine: Equatable {
    let athleteID: String
    let points: Int
    let didPlay: Bool
    /// Field goals made / attempted. nil when ESPN doesn't give them.
    var fgm: Int? = nil
    var fga: Int? = nil
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

enum ClientError: Error {
    case badStatus
    case noData
}

actor ESPNClient {
    static let shared = ESPNClient()

    private let base = "https://site.api.espn.com/apis/site/v2/sports/basketball/nba"
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
                excluded: excluded
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
                var fgm: Int? = nil
                var fga: Int? = nil
                if let i = fgIdx, i < stats.count {
                    let parts = stats[i].split(separator: "-")
                    if parts.count == 2, let m = Int(parts[0]), let t = Int(parts[1]) {
                        fgm = m
                        fga = t
                    }
                }
                out[id] = PlayerLine(athleteID: id, points: pts, didPlay: played, fgm: fgm, fga: fga)
            }
        }
        return out
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
    struct TeamPlayers: Decodable { let statistics: [StatGroup]? }
    struct StatGroup: Decodable {
        let names: [String]?
        let labels: [String]?
        let athletes: [AthleteLine]?
    }
    struct AthleteLine: Decodable {
        let athlete: Athlete?
        let stats: [String]?
        let didNotPlay: Bool?
    }
    struct Athlete: Decodable { let id: String? }
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
