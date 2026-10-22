import Foundation
import Combine

/// One player's nth NBA game of the league week.
struct GameLine: Equatable, Codable {
    let eventID: String
    let date: Date
    let opponent: String       // "vs BOS" / "@ BOS"
    let state: GameState
    let statusText: String     // "Q3 4:12", "Final", ...
    let points: Int?           // nil until he has a stat line
    /// Field goals made / attempted. nil until he has a stat line, and for weeks saved before this was tracked.
    var fgm: Int? = nil
    var fga: Int? = nil
}

struct NightRow: Identifiable {
    var id: String { "\(player.id.uuidString)-\(gameIndex)" }
    let player: RosterPlayer
    let gameIndex: Int
    let line: GameLine
    let result: PlayerGameResult
}

struct WeekResults: Codable {
    var lines: [UUID: [GameLine?]]                // per player, 2 entries
    var perGame: [[UUID: PlayerGameResult]]       // index 0 and 1

    func result(for playerID: UUID, game: Int) -> PlayerGameResult? { perGame[game][playerID] }
    func line(for playerID: UUID, game: Int) -> GameLine? {
        guard let list = lines[playerID], game < list.count else { return nil }
        return list[game]
    }

    func gameTotal(_ game: Int) -> Int { perGame[game].values.reduce(0) { $0 + $1.total } }
    var weekTotal: Int { gameTotal(0) + gameTotal(1) }
    var bonusTotal: Int { perGame.flatMap { $0.values }.reduce(0) { $0 + $1.bonus } }

    func playerTotal(_ playerID: UUID) -> Int {
        (result(for: playerID, game: 0)?.total ?? 0) + (result(for: playerID, game: 1)?.total ?? 0)
    }
}

/// The last scores we loaded for a week, kept so the app never opens to a blank screen.
private struct CachedWeek: Codable {
    var results: WeekResults
    var savedAt: Date
}

@MainActor
final class WeekStore: ObservableObject {
    @Published private(set) var weekStart: Date
    @Published private(set) var results: WeekResults?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var hasLive = false
    /// True while the numbers on screen are saved ones from an earlier load.
    @Published private(set) var isStale = false

    let rules = ScoringRules()

    private let directory: PlayerDirectory
    private let lineupStore: LineupStore
    private var teamGames: [String: [GameInfo]] = [:]
    private var boxes: [String: [String: PlayerLine]] = [:]   // eventID -> athleteID -> line
    private var rerunRequested = false

    /// Finished weeks, saved on the phone so they never need ESPN again. Keyed like LineupStore snapshots.
    @Published private var frozen: [String: WeekResults]
    private let frozenURL: URL
    private var cache: [String: CachedWeek]
    private let cacheURL: URL

    init(
        directory: PlayerDirectory, lineupStore: LineupStore,
        frozenURL: URL = Storage.url("frozen-weeks.json"),
        cacheURL: URL = Storage.url("last-results.json")
    ) {
        self.directory = directory
        self.lineupStore = lineupStore
        self.frozenURL = frozenURL
        self.cacheURL = cacheURL
        self.weekStart = ET.weekStart(containing: Date())
        if let data = try? Data(contentsOf: frozenURL),
           let saved = try? JSONDecoder().decode([String: WeekResults].self, from: data) {
            self.frozen = saved
        } else {
            self.frozen = [:]
        }
        if let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode([String: CachedWeek].self, from: data) {
            self.cache = saved
        } else {
            self.cache = [:]
        }
        showSaved(for: LineupStore.key(for: weekStart))
    }

    /// Puts whatever we already have for a week on screen right away: the final scores if the week is saved,
    /// else the last load. A refresh then replaces it.
    private func showSaved(for key: String) {
        if let done = frozen[key] {
            results = done
            isStale = false
            lastUpdated = nil
        } else if let saved = cache[key] {
            results = saved.results
            isStale = true
            lastUpdated = saved.savedAt
        } else {
            results = nil
            isStale = false
            lastUpdated = nil
        }
    }

    /// True once a week's games are all final and its scores are saved on this phone.
    var isFrozen: Bool { frozen[LineupStore.key(for: weekStart)] != nil }

    // MARK: Week navigation

    /// Tuesday that starts Week 1 of the 2026/27 USACBL season.
    static let seasonStart: Date = ET.startOfDay(ET.cal.date(from: DateComponents(year: 2026, month: 10, day: 20)) ?? Date())

    /// League week number for a week starting on `start`. 0 means before Week 1.
    static func weekNumber(for start: Date) -> Int {
        let days = ET.cal.dateComponents([.day], from: seasonStart, to: ET.startOfDay(start)).day ?? 0
        return days >= 0 ? days / 7 + 1 : 0
    }

    var weekNumber: Int { Self.weekNumber(for: weekStart) }
    var weekLabel: String { weekNumber >= 1 ? "Week \(weekNumber)" : "Preseason" }

    var days: [Date] { (0..<7).map { ET.addDays($0, to: weekStart) } }
    var weekEnd: Date { ET.addDays(6, to: weekStart) }
    var isCurrentWeek: Bool { weekStart == ET.weekStart(containing: Date()) }

    func shiftWeek(by n: Int) {
        setWeek(ET.addDays(7 * n, to: weekStart))
    }

    func goToCurrentWeek() {
        setWeek(ET.weekStart(containing: Date()))
    }

    private func setWeek(_ start: Date) {
        weekStart = start
        lineupStore.setViewedWeek(start)
        showSaved(for: LineupStore.key(for: start))   // saved scores show instantly
        hasLive = false
        teamGames = [:]
        Task { await refresh() }
    }

    // MARK: Refresh

    func refresh() async {
        if isLoading {
            rerunRequested = true
            return
        }
        isLoading = true
        repeat {
            rerunRequested = false
            do {
                try await load()
                errorMessage = nil
                lastUpdated = Date()
            } catch {
                errorMessage = "Couldn't reach ESPN. Pull down to retry."
            }
        } while rerunRequested
        isLoading = false
    }

    private func load() async throws {
        // A finished week is already saved. No network needed.
        if let done = frozen[LineupStore.key(for: weekStart)] {
            results = done
            isStale = false
            hasLive = false
            return
        }

        await directory.load()
        guard directory.isLoaded else { throw ClientError.noData }
        await directory.loadInjuries()

        // Link any roster players we haven't matched to an ESPN id yet.
        for p in lineupStore.lineup.all where p.espnID == nil && !p.isEmpty {
            if let match = directory.resolve(name: p.name, teamHint: p.teamHint) {
                lineupStore.link(playerID: p.id, espnID: match.id)
            }
        }
        let lineup = lineupStore.lineup
        let start = weekStart

        // 1. Schedule for ten days from Tuesday, so a team's 2nd game still lands in the week when it spills past Monday.
        let dayList = (0..<10).map { ET.addDays($0, to: start) }
        var games: [String: GameInfo] = [:]
        var failedDays = 0
        await withTaskGroup(of: [GameInfo]?.self) { group in
            for d in dayList {
                group.addTask { try? await ESPNClient.shared.scoreboard(day: d) }
            }
            for await list in group {
                if let list {
                    for g in list { games[g.id] = g }
                } else {
                    failedDays += 1
                }
            }
        }
        if failedDays == dayList.count { throw ClientError.noData }

        // 2. Each team's first two games, in order.
        var byTeam: [String: [GameInfo]] = [:]
        for g in games.values.filter({ !$0.excluded }).sorted(by: { $0.date < $1.date }) {
            byTeam[g.homeID, default: []].append(g)
            byTeam[g.awayID, default: []].append(g)
        }
        byTeam = byTeam.mapValues { Array($0.prefix(2)) }

        // 3. Box scores for started games involving a rostered player's team. Finals are cached for good.
        var needed = Set<String>()
        for p in lineup.all {
            guard let id = p.espnID, let tid = directory.player(id: id)?.teamID else { continue }
            for g in byTeam[tid] ?? [] where g.state != .scheduled {
                if g.state == .live || boxes[g.id] == nil { needed.insert(g.id) }
            }
        }
        let fetched = await withTaskGroup(of: (String, [String: PlayerLine]?).self) { group -> [String: [String: PlayerLine]] in
            for eid in needed {
                group.addTask { (eid, try? await ESPNClient.shared.boxscore(eventID: eid)) }
            }
            var out: [String: [String: PlayerLine]] = [:]
            for await (eid, box) in group {
                if let box { out[eid] = box }
            }
            return out
        }
        for (eid, box) in fetched { boxes[eid] = box }

        guard start == weekStart else { return }   // user changed weeks mid-fetch
        teamGames = byTeam
        recompute(lineup: lineup)
    }

    // MARK: Scoring

    private func recompute(lineup: Lineup) {
        var lines: [UUID: [GameLine?]] = [:]
        var availability: [[UUID: Availability]] = [[:], [:]]
        var live = false
        var settled = true    // every counted game is final and has a box score
        let windowClosed = Date() >= ET.addDays(10, to: weekStart)

        for p in lineup.all {
            if p.isEmpty {
                // Empty slot: treated like a player who never plays, so it scores zero and never gets promoted.
                availability[0][p.id] = .dnp
                availability[1][p.id] = .dnp
                lines[p.id] = [nil, nil]
                continue
            }
            var playerLines: [GameLine?] = [nil, nil]
            let eid = p.espnID
            let tid = eid.flatMap { directory.player(id: $0)?.teamID }
            if eid == nil || tid == nil { settled = false }   // unmatched player: don't save a guess

            for idx in 0..<2 {
                guard let eid, let tid, let teamList = teamGames[tid], idx < teamList.count else {
                    availability[idx][p.id] = .pending
                    if !windowClosed { settled = false }
                    continue
                }
                let game = teamList[idx]
                let box = boxes[game.id]
                let stat = box?[eid]
                if game.state != .final || box == nil { settled = false }

                var a = Availability.pending
                switch game.state {
                case .scheduled:
                    a = .pending
                case .live:
                    live = true
                    if let stat, stat.didPlay { a = .live(stat.points) }
                case .final:
                    if box == nil {
                        a = .pending                       // box score didn't load; don't call him a DNP
                    } else if let stat, stat.didPlay {
                        a = .played(stat.points)
                    } else {
                        a = .dnp
                    }
                }
                availability[idx][p.id] = a

                let opponent = (tid == game.homeID) ? "vs \(game.awayAbbr)" : "@ \(game.homeAbbr)"
                var pts: Int? = nil
                if case .live(let x) = a { pts = x }
                if case .played(let x) = a { pts = x }
                var fgm: Int? = nil
                var fga: Int? = nil
                if pts != nil, let stat {
                    fgm = stat.fgm
                    fga = stat.fga
                }
                playerLines[idx] = GameLine(
                    eventID: game.id, date: game.date, opponent: opponent, state: game.state, statusText: game.statusText,
                    points: pts, fgm: fgm, fga: fga
                )
            }
            lines[p.id] = playerLines
        }

        let perGame = (0..<2).map { ScoringEngine.resolve(lineup: lineup, availability: availability[$0], rules: rules) }
        let computed = WeekResults(lines: lines, perGame: perGame)
        results = computed
        hasLive = live
        isStale = false
        let key = LineupStore.key(for: weekStart)
        cache[key] = CachedWeek(results: computed, savedAt: Date())
        if cache.count > 6 {
            let oldest = cache.sorted { $0.value.savedAt < $1.value.savedAt }.prefix(cache.count - 6).map { $0.key }
            for k in oldest { cache[k] = nil }
        }

        // Save the week once it's over, every game is final, and a day has passed for stat corrections.
        if settled && Date() >= ET.addDays(2, to: weekEnd) {
            frozen[key] = computed
            cache[key] = nil
            saveFrozen()
        }
        saveCache()
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    private func saveFrozen() {
        if let data = try? JSONEncoder().encode(frozen) {
            try? data.write(to: frozenURL, options: .atomic)
        }
    }

    /// Today's injury report. Only shown for the current and future weeks, so it isn't pinned on old results.
    func injury(for p: RosterPlayer) -> Injury? {
        guard lineupStore.isEditable, !p.isEmpty else { return nil }
        return directory.injury(for: p)
    }

    // MARK: Nightly view

    /// Rostered players whose team plays on `day` (ET) and whose game counts toward this league week.
    func rows(on day: Date) -> [NightRow] {
        guard let results else { return [] }
        var out: [NightRow] = []
        for p in lineupStore.lineup.all {
            for idx in 0..<2 {
                guard let line = results.line(for: p.id, game: idx),
                      let result = results.result(for: p.id, game: idx),
                      ET.startOfDay(line.date) == day else { continue }
                out.append(NightRow(player: p, gameIndex: idx, line: line, result: result))
            }
        }
        // Same order as the Lineup tab: starters (G, G, F, F, C), bench, then deep bench.
        return out
    }

    func nightTotal(on day: Date) -> Int {
        rows(on: day).reduce(0) { $0 + $1.result.total }
    }
}
