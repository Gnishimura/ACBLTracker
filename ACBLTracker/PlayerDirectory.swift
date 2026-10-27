import Foundation
import Combine

/// Everything we show next to a name: headshot, team abbreviation, team logo.
struct PlayerDisplay {
    let headshot: URL?
    let teamAbbr: String
    let teamLogo: URL?
    let linked: Bool
    var teamColor: String? = nil
}

private struct DirectoryCache: Codable {
    var fetchedAt: Date
    var teams: [DirectoryTeam]
    var players: [DirectoryPlayer]
}

/// League-wide player + team directory built from ESPN team rosters. Cached on disk for 12 hours.
@MainActor
final class PlayerDirectory: ObservableObject {
    @Published private(set) var players: [DirectoryPlayer] = []
    @Published private(set) var isLoaded = false
    @Published private(set) var injuries: [String: Injury] = [:]
    private var injuriesFetchedAt: Date = .distantPast
    /// Regular-season points per game, keyed by ESPN athlete id.
    @Published private(set) var seasonPPG: [String: Double] = [:]
    private var ppgFetchedAt: [String: Date] = [:]

    private var teamsByID: [String: DirectoryTeam] = [:]
    private var playersByID: [String: DirectoryPlayer] = [:]
    private var fetchedAt: Date = .distantPast
    private let cacheURL = Storage.url("directory.json")
    private let maxAge: TimeInterval = 12 * 3600

    func load(force: Bool = false) async {
        if players.isEmpty, let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(DirectoryCache.self, from: data) {
            apply(cache)
            if cache.teams.allSatisfy({ $0.color == nil }) { fetchedAt = .distantPast }
        }
        if !force && Date().timeIntervalSince(fetchedAt) < maxAge && !players.isEmpty { return }

        do {
            let teams = try await ESPNClient.shared.teams()
            let all = await withTaskGroup(of: [DirectoryPlayer].self) { group -> [DirectoryPlayer] in
                for t in teams {
                    group.addTask { (try? await ESPNClient.shared.roster(team: t)) ?? [] }
                }
                var merged: [DirectoryPlayer] = []
                for await list in group { merged += list }
                return merged
            }
            guard !all.isEmpty else { return }
            let cache = DirectoryCache(fetchedAt: Date(), teams: teams, players: all)
            apply(cache)
            if let data = try? JSONEncoder().encode(cache) {
                try? data.write(to: cacheURL, options: .atomic)
            }
        } catch {
            // Keep whatever the cache gave us; the caller checks isLoaded.
        }
    }

    /// Injury report, refreshed at most every 5 minutes. Keeps the last good copy if ESPN fails.
    func loadInjuries(force: Bool = false) async {
        if !force && Date().timeIntervalSince(injuriesFetchedAt) < 300 { return }
        if let fresh = try? await ESPNClient.shared.injuries() {
            injuries = fresh
            injuriesFetchedAt = Date()
        }
    }

    /// Season scoring averages for these players, each refreshed at most every 30 minutes (every time with `force`).
    /// A failed fetch isn't recorded, so it's retried on the next call.
    func loadSeasonPPG(for ids: [String], force: Bool = false) async {
        let due = Set(ids.filter { force || Date().timeIntervalSince(ppgFetchedAt[$0] ?? .distantPast) > 1800 })
        guard !due.isEmpty else { return }
        let fresh = await withTaskGroup(of: (String, Double?)?.self) { group -> [(String, Double?)] in
            for id in due {
                group.addTask { (try? await ESPNClient.shared.gameLog(athleteID: id, force: force)).map { (id, $0.seasonPPG) } }
            }
            var out: [(String, Double?)] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
        for (id, ppg) in fresh {
            seasonPPG[id] = ppg
            ppgFetchedAt[id] = Date()
        }
    }

    func injury(for p: RosterPlayer) -> Injury? {
        if let id = p.espnID {
            if let hit = injuries[id] { return hit }
            if let name = playersByID[id]?.name, let hit = injuries["name:" + name.normalizedName] { return hit }
        }
        return injuries["name:" + p.name.normalizedName]
    }

    private func apply(_ cache: DirectoryCache) {
        fetchedAt = cache.fetchedAt
        teamsByID = Dictionary(uniqueKeysWithValues: cache.teams.map { ($0.id, $0) })
        playersByID = Dictionary(cache.players.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        players = cache.players
        isLoaded = !cache.players.isEmpty
    }

    func player(id: String) -> DirectoryPlayer? { playersByID[id] }

    func display(for p: RosterPlayer) -> PlayerDisplay {
        if let id = p.espnID, let dp = playersByID[id] {
            let team = teamsByID[dp.teamID]
            let logo = team?.logo ?? "https://a.espncdn.com/i/teamlogos/nba/500/\(dp.teamAbbr.lowercased()).png"
            return PlayerDisplay(headshot: dp.headshotURL, teamAbbr: dp.teamAbbr, teamLogo: URL(string: logo), linked: true, teamColor: team?.color)
        }
        return PlayerDisplay(headshot: nil, teamAbbr: p.teamHint, teamLogo: nil, linked: false)
    }

    func display(for dp: DirectoryPlayer) -> PlayerDisplay {
        let logo = teamsByID[dp.teamID]?.logo ?? "https://a.espncdn.com/i/teamlogos/nba/500/\(dp.teamAbbr.lowercased()).png"
        return PlayerDisplay(headshot: dp.headshotURL, teamAbbr: dp.teamAbbr, teamLogo: URL(string: logo), linked: true, teamColor: teamsByID[dp.teamID]?.color)
    }

    func search(_ query: String) -> [DirectoryPlayer] {
        let key = query.normalizedName
        guard key.count >= 2 else { return [] }
        return players
            .filter { $0.name.normalizedName.contains(key) }
            .sorted { $0.name < $1.name }
            .prefix(40)
            .map { $0 }
    }

    /// Matches a league-sheet name to an ESPN player. The sheet has nicknames and typos
    /// ("Cam Johnson", "Jeremi Grant"), so this tries three increasingly loose passes.
    func resolve(name: String, teamHint: String) -> DirectoryPlayer? {
        let target = name.normalizedName
        let hint = TeamAlias.canon(teamHint)

        let exact = players.filter { $0.name.normalizedName == target }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 {
            return exact.first { TeamAlias.canon($0.teamAbbr) == hint } ?? exact[0]
        }

        // Same last name on the team the sheet says.
        let lastName = target.split(separator: " ").last.map(String.init) ?? target
        let byLastAndTeam = players.filter {
            let last = $0.name.normalizedName.split(separator: " ").last.map(String.init) ?? ""
            return last == lastName && TeamAlias.canon($0.teamAbbr) == hint
        }
        if byLastAndTeam.count == 1 { return byLastAndTeam[0] }

        // Small typo distance, only if there is a single best candidate.
        let scored = players
            .map { (player: $0, distance: levenshtein($0.name.normalizedName, target)) }
            .filter { $0.distance <= 2 }
            .sorted { $0.distance < $1.distance }
        if let best = scored.first, scored.count == 1 || scored[1].distance > best.distance {
            return best.player
        }
        return nil
    }
}
