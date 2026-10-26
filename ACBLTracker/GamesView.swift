import SwiftUI

/// Every NBA game on a day, whether or not your players are in it. Tap a game for a short box score.
struct GamesView: View {
    @State private var day: Date = ET.startOfDay(Date())
    @State private var games: [GameInfo]?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                if let games {
                    if games.isEmpty {
                        Text("No NBA games on this date").foregroundStyle(.secondary)
                    } else {
                        ForEach(games) { game in
                            NavigationLink { GameBoxView(game: game) } label: { GameRow(game: game) }
                        }
                    }
                } else if failed {
                    Text("Couldn't load games").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading...").foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.bottom, 80, for: .scrollContent)
            .navigationTitle("Games")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { dayStepper } }
            .refreshable { await Task { await load() }.value }
            // New day: start fresh. While a game is live, refresh once a minute.
            .task(id: day) {
                games = nil
                failed = false
                await load()
                while !Task.isCancelled, games?.contains(where: { $0.state == .live }) == true {
                    try? await Task.sleep(for: .seconds(60))
                    if Task.isCancelled { break }
                    await load()
                }
            }
        }
    }

    private var dayStepper: some View {
        HStack(spacing: 12) {
            Button { day = ET.addDays(-1, to: day) } label: { Image(systemName: "chevron.left") }
            VStack(spacing: 0) {
                Text(ET.format("EEE, MMM d", day)).font(.subheadline.bold())
                if day != ET.startOfDay(Date()) {
                    Button("Back to today") { day = ET.startOfDay(Date()) }
                        .font(.caption2)
                }
            }
            Button { day = ET.addDays(1, to: day) } label: { Image(systemName: "chevron.right") }
        }
    }

    private func load() async {
        do {
            games = try await ESPNClient.shared.scoreboard(day: day)
            failed = false
        } catch {
            // Keep the last good scores on a failed refresh.
            if games == nil { failed = true }
        }
    }
}

private struct GameRow: View {
    let game: GameInfo

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                teamLine(game.awayAbbr, game.awayScore, wins: winner == game.awayID)
                teamLine(game.homeAbbr, game.homeScore, wins: winner == game.homeID)
            }
            Spacer()
            Text(statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(game.state == .live ? Color.green : Color.secondary)
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        game.state == .scheduled ? DateParsing.localTime(game.date) : game.statusText
    }

    /// Team id of the winner once the game is final.
    private var winner: String? {
        guard game.state == .final, let h = game.homeScore, let a = game.awayScore, h != a else { return nil }
        return h > a ? game.homeID : game.awayID
    }

    private func teamLine(_ abbr: String, _ score: Int?, wins: Bool) -> some View {
        HStack(spacing: 8) {
            TeamLogo(abbr: abbr)
            Text(abbr).font(.subheadline.weight(.semibold)).frame(width: 44, alignment: .leading)
            if let score {
                Text("\(score)")
                    .font(.headline.weight(wins ? .heavy : .regular)).monospacedDigit()
                    .foregroundStyle(game.state == .final && !wins ? Color.secondary : Color.primary)
            }
        }
    }
}

private struct TeamLogo: View {
    let abbr: String

    var body: some View {
        AsyncImage(url: URL(string: "https://a.espncdn.com/i/teamlogos/nba/500/\(abbr.lowercased()).png")) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Color.clear
        }
        .frame(width: 22, height: 22)
    }
}

/// Points, field goals and minutes for everyone who suited up. Your rostered players are starred.
/// Tap a player for his season average, game log and news.
struct GameBoxView: View {
    let game: GameInfo
    @EnvironmentObject var lineupStore: LineupStore
    @EnvironmentObject var directory: PlayerDirectory
    @State private var teams: [TeamBox]?
    @State private var failed = false
    @State private var selected: RosterPlayer?

    var body: some View {
        List {
            if let teams {
                if teams.allSatisfy({ $0.players.isEmpty }) {
                    Text("The box score shows up once the game tips off").foregroundStyle(.secondary)
                } else {
                    ForEach(ordered(teams)) { team in
                        Section {
                            columnHeader
                            ForEach(team.players) { p in
                                Button { selected = rosterPlayer(p, team: team) } label: { playerRow(p) }
                                    .buttonStyle(.plain)
                            }
                        } header: {
                            HStack {
                                Text(team.name)
                                Spacer()
                                Text("\(team.players.compactMap(\.points).reduce(0, +))")
                                    .font(.headline).monospacedDigit().foregroundStyle(.primary)
                            }
                        }
                    }
                }
            } else if failed {
                Text("Couldn't load the box score").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading...").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("\(game.awayAbbr) @ \(game.homeAbbr)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { PlayerDetailView(player: $0) }
        .refreshable { await Task { await load() }.value }
        .task {
            await load()
            guard game.state != .final else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { break }
                await load()
            }
        }
    }

    /// Away team first, matching the scoreboard.
    private func ordered(_ teams: [TeamBox]) -> [TeamBox] {
        teams.filter { $0.id == game.awayID } + teams.filter { $0.id != game.awayID }
    }

    private var columnHeader: some View {
        HStack {
            Text("PLAYER").frame(maxWidth: .infinity, alignment: .leading)
            Text("MIN").frame(width: 36, alignment: .trailing)
            Text("FG").frame(width: 48, alignment: .trailing)
            Text("PTS").frame(width: 36, alignment: .trailing)
        }
        .font(.caption2.bold())
        .foregroundStyle(.secondary)
    }

    /// Your own roster entry when he's on it (keeps your league position); otherwise one built from ESPN's data.
    private func rosterPlayer(_ p: BoxPlayer, team: TeamBox) -> RosterPlayer {
        if let mine = lineupStore.lineup.all.first(where: { $0.espnID == p.id }) { return mine }
        let position = Position.fromESPN(directory.player(id: p.id)?.position ?? "")
        return RosterPlayer(name: p.name, position: position, teamHint: team.abbr, espnID: p.id)
    }

    private func playerRow(_ p: BoxPlayer) -> some View {
        let mine = lineupStore.lineup.contains(espnID: p.id)
        return HStack {
            HStack(spacing: 4) {
                if mine { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.orange) }
                PlayerName(name: p.name)
                if p.starter { Text("S").font(.caption2.bold()).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if p.didPlay {
                Text(p.minutes ?? "-").frame(width: 36, alignment: .trailing)
                Text(p.fgm.flatMap { m in p.fga.map { "\(m)-\($0)" } } ?? "-").frame(width: 48, alignment: .trailing)
                Text(p.points.map(String.init) ?? "-").bold().frame(width: 36, alignment: .trailing)
            } else {
                Text("DNP").font(.caption.bold()).foregroundStyle(.secondary)
            }
        }
        .font(.subheadline).monospacedDigit()
        .opacity(p.didPlay ? 1 : 0.5)
        .contentShape(Rectangle())
    }

    private func load() async {
        do {
            teams = try await ESPNClient.shared.teamBoxes(eventID: game.id)
            failed = false
        } catch {
            if teams == nil { failed = true }
        }
    }
}
