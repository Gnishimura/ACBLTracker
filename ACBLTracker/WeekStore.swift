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
    var box: BoxStats? = nil
}

struct NightRow: Identifiable {
    var id: String { "\(player.id.uuidString)-\(gameIndex)" }
    let player: RosterPlayer
    let gameIndex: Int          // 0 and 1 count; 2 and up are off-night games
    let line: GameLine
    let result: PlayerGameResult

    /// The team's 3rd or later game of the week, which never counts.
    var isOffNight: Bool { gameIndex >= 2 }
}

/// A game past a team's first two of the week. Shown on the Nightly tab, never scored.
struct OffNightGame: Codable {
    let line: GameLine
    let availability: Availability
}

struct WeekResults: Codable {
    var lines: [UUID: [GameLine?]]                // per player, 2 entries
    var perGame: [[UUID: PlayerGameResult]]       // index 0 and 1
    /// Per player, the team's 3rd and later games inside the week. nil for weeks saved before this was tracked.
    var offNights: [UUID: [OffNightGame]]? = nil

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
    private var offNightGames: [String: [GameInfo]] = [:]   // each team's 3rd+ games within Tue-Mon
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
        offNightGames = [:]
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

    /// Pull to refresh: the injury report and season averages, which otherwise update on a timer, then scores.
    func refreshAll() async {
        await directory.loadInjuries(force: true)
        async let ppg: Void = directory.loadSeasonPPG(for: lineupStore.lineup.all.compactMap(\.espnID), force: true)
        await refresh()
        await ppg
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

        // 2. Each team's first two games, in order, then any later ones inside the Tue-Mon week (off nights).
        var allByTeam: [String: [GameInfo]] = [:]
        for g in games.values.filter({ !$0.excluded }).sorted(by: { $0.date < $1.date }) {
            allByTeam[g.homeID, default: []].append(g)
            allByTeam[g.awayID, default: []].append(g)
        }
        let byTeam = allByTeam.mapValues { Array($0.prefix(2)) }
        let weekOver = ET.addDays(7, to: start)
        let offByTeam = allByTeam.mapValues { $0.dropFirst(2).filter { $0.date < weekOver } }

        // 3. Box scores for started games involving a rostered player's team. Finals are cached for good.
        var needed = Set<String>()
        for p in lineup.all {
            guard let id = p.espnID, let tid = directory.player(id: id)?.teamID else { continue }
            for g in (byTeam[tid] ?? []) + (offByTeam[tid] ?? []) where g.state != .scheduled {
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
        offNightGames = offByTeam
        recompute(lineup: lineup)
    }

    // MARK: Scoring

    private func recompute(lineup: Lineup) {
        var lines: [UUID: [GameLine?]] = [:]
        var availability: [[UUID: Availability]] = [[:], [:]]
        var offNights: [UUID: [OffNightGame]] = [:]
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
                if game.state != .final || boxes[game.id] == nil { settled = false }
                if game.state == .live { live = true }
                let (a, line) = gameLine(game, athleteID: eid, teamID: tid)
                availability[idx][p.id] = a
                playerLines[idx] = line
            }
            lines[p.id] = playerLines

            if let eid, let tid, let extra = offNightGames[tid], !extra.isEmpty {
                offNights[p.id] = extra.map { game in
                    if game.state != .final || boxes[game.id] == nil { settled = false }
                    if game.state == .live { live = true }
                    let (a, line) = gameLine(game, athleteID: eid, teamID: tid)
                    return OffNightGame(line: line, availability: a)
                }
            }
        }

        let perGame = (0..<2).map { ScoringEngine.resolve(lineup: lineup, availability: availability[$0], rules: rules) }
        let computed = WeekResults(lines: lines, perGame: perGame, offNights: offNights)
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

    /// One player's status and stat line for one game, from the saved box score.
    private func gameLine(_ game: GameInfo, athleteID eid: String, teamID tid: String) -> (Availability, GameLine) {
        let box = boxes[game.id]
        let stat = box?[eid]
        var a = Availability.pending
        switch game.state {
        case .scheduled:
            a = .pending
        case .live:
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

        let opponent = (tid == game.homeID) ? "vs \(game.awayAbbr)" : "@ \(game.homeAbbr)"
        var pts: Int? = nil
        if case .live(let x) = a { pts = x }
        if case .played(let x) = a { pts = x }
        var fgm: Int? = nil
        var fga: Int? = nil
        var boxStats: BoxStats? = nil
        if pts != nil, let stat {
            fgm = stat.fgm
            fga = stat.fga
            boxStats = stat.box
        }
        let line = GameLine(
            eventID: game.id, date: game.date, opponent: opponent, state: game.state, statusText: game.statusText,
            points: pts, fgm: fgm, fga: fga, box: boxStats
        )
        return (a, line)
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

    /// Rostered players whose team plays on `day` (ET): counting games (the team's first two of the week) and off nights.
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
            for (i, game) in (results.offNights?[p.id] ?? []).enumerated() where ET.startOfDay(game.line.date) == day {
                let result = PlayerGameResult(role: .notCounted, availability: game.availability, countedPoints: 0, bonus: 0)
                out.append(NightRow(player: p, gameIndex: 2 + i, line: game.line, result: result))
            }
        }
        // Same order as the Lineup tab: starters (G, G, F, F, C), bench, then deep bench.
        return out
    }

    func nightTotal(on day: Date) -> Int {
        rows(on: day).reduce(0) { $0 + $1.result.total }
    }

    // MARK: Bench regret

    struct Regret: Identifiable {
        let game: Int            // 0 or 1
        let starter: RosterPlayer
        let sub: RosterPlayer
        let gain: Int
        var id: String { "\(game)-\(starter.id.uuidString)" }
    }

    /// Subs who outscored the starter at their position in a finished game, one entry per starter per game.
    /// The gain is what the sub would have counted as a starter (full points plus any bonus) minus what the starter counted.
    /// It ignores the half points the sub already counted and any half points the benched starter would pick up.
    func regrets() -> [Regret] {
        guard let results else { return [] }
        let lineup = lineupStore.lineup
        var out: [Regret] = []
        for game in 0..<2 {
            let perGame = results.perGame[game]
            var taken = Set<UUID>()
            for (i, starter) in lineup.starters.enumerated() where !starter.isEmpty {
                guard let sr = perGame[starter.id], sr.role == .starter, case .played = sr.availability else { continue }
                let slotPosition = Lineup.starterPositions[i]
                var best: (sub: RosterPlayer, gain: Int)? = nil
                for sub in lineup.subs where !sub.isEmpty && sub.position == slotPosition && !taken.contains(sub.id) {
                    guard let r = perGame[sub.id], r.role != .promoted, case .played(let pts) = r.availability else { continue }
                    let gain = pts + rules.bonus(for: pts) - sr.total
                    if gain > (best?.gain ?? 0) { best = (sub, gain) }
                }
                if let best {
                    taken.insert(best.sub.id)
                    out.append(Regret(game: game, starter: starter, sub: best.sub, gain: best.gain))
                }
            }
        }
        return out
    }

    /// "Outscored J. Brunson by 8 in G1" for a sub who would have beaten his starter.
    /// Checked per sub, so every sub who beat a same-position starter gets a note even when a better sub
    /// already claimed that starter's slot in the total.
    func regretNote(for playerID: UUID) -> String? {
        guard let results else { return nil }
        let lineup = lineupStore.lineup
        guard let sub = lineup.subs.first(where: { $0.id == playerID && !$0.isEmpty }) else { return nil }
        var parts: [String] = []
        for game in 0..<2 {
            let perGame = results.perGame[game]
            guard let r = perGame[sub.id], r.role != .promoted, case .played(let pts) = r.availability else { continue }
            var best: (starter: RosterPlayer, gain: Int)? = nil
            for (i, starter) in lineup.starters.enumerated()
            where !starter.isEmpty && Lineup.starterPositions[i] == sub.position {
                guard let sr = perGame[starter.id], sr.role == .starter, case .played = sr.availability else { continue }
                let gain = pts + rules.bonus(for: pts) - sr.total
                if gain > (best?.gain ?? 0) { best = (starter, gain) }
            }
            if let best {
                parts.append("Outscored \(best.starter.name.abbreviatedName) by \(best.gain) in G\(game + 1)")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Points that sat on the bench across both games (sum of the best swap for each starter).
    var regretTotal: Int { regrets().reduce(0) { $0 + $1.gain } }

    // MARK: History

    struct HistoryEntry: Identifiable {
        let key: String
        let weekNumber: Int
        let total: Int
        let game1: Int
        let game2: Int
        let bonus: Int
        let isFinal: Bool
        var id: String { key }
    }

    private func weekDate(_ key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return ET.cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    /// One entry per league week we have scores for: saved finished weeks, plus the last load of any other week.
    func history() -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        func add(_ key: String, _ r: WeekResults, final: Bool) {
            guard let d = weekDate(key) else { return }
            let n = Self.weekNumber(for: d)
            guard n >= 1 else { return }
            out.append(HistoryEntry(
                key: key, weekNumber: n, total: r.weekTotal,
                game1: r.gameTotal(0), game2: r.gameTotal(1), bonus: r.bonusTotal, isFinal: final
            ))
        }
        for (key, r) in frozen { add(key, r, final: true) }
        for (key, c) in cache where frozen[key] == nil { add(key, c.results, final: false) }
        return out.sorted { $0.weekNumber < $1.weekNumber }
    }

    /// Finished games with a stat line, newest first, from the weeks saved on this phone. Only the two counting games
    /// per week, but it works when ESPN's game log has nothing yet.
    func savedGames(for playerID: UUID) -> [RecentGame] {
        var all: [WeekResults] = Array(frozen.values) + cache.filter { frozen[$0.key] == nil }.map { $0.value.results }
        if let r = results { all.append(r) }
        var seen = Set<String>()
        var out: [RecentGame] = []
        for r in all {
            for line in (r.lines[playerID] ?? []).compactMap({ $0 }) where line.state == .final {
                guard let pts = line.points, !seen.contains(line.eventID) else { continue }
                seen.insert(line.eventID)
                out.append(RecentGame(
                    id: line.eventID, date: line.date, opponent: line.opponent, result: nil, points: pts,
                    minutes: line.box?.minutes,
                    fg: line.fgm.flatMap { m in line.fga.map { "\(m)-\($0)" } },
                    reb: line.box?.reb, ast: line.box?.ast
                ))
            }
        }
        out.sort { $0.date > $1.date }
        return Array(out.prefix(5))
    }
}
