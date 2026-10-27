import SwiftUI

/// Tap a player on the Lineup tab or in a Games box score: his season average, game log and latest news.
struct PlayerDetailView: View {
    let player: RosterPlayer
    @EnvironmentObject var week: WeekStore
    @EnvironmentObject var directory: PlayerDirectory
    @Environment(\.dismiss) private var dismiss

    @State private var recent: [RecentGame]?
    @State private var recentFailed = false
    @State private var preseason: [RecentGame] = []
    @State private var seasonPPG: Double?
    @State private var showAllGames = false
    @State private var news: [PlayerNews]?
    @State private var newsFailed = false
    @State private var expandedNews: Set<String> = []

    var body: some View {
        let display = directory.display(for: player)
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        HeadshotView(url: display.headshot, size: 64, teamColor: display.teamColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(player.name).font(.title3.bold())
                            HStack(spacing: 6) {
                                PositionPill(position: player.position)
                                TeamTag(display: display)
                                if let ppg = seasonPPG ?? player.espnID.flatMap({ directory.seasonPPG[$0] }) {
                                    Text(String(format: "%.1f ppg", ppg))
                                        .font(.caption.weight(.semibold)).monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let injury = week.injury(for: player) {
                                Text(injury.summary).font(.caption.weight(.semibold)).foregroundStyle(.red)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                recentSection

                newsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(player.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task { await loadRecent() }
            .task { await loadNews() }
            .refreshable {
                // Its own task, so a redraw mid-pull can't cancel the network calls.
                await Task {
                    async let recent: Void = loadRecent(force: true)
                    async let news: Void = loadNews(force: true)
                    await directory.loadInjuries(force: true)
                    _ = await (recent, news)
                }.value
            }
        }
        .presentationDetents([.medium, .large])
        // A pull down on the list refreshes it instead of shrinking the sheet. Drag the title bar to resize or close.
        .presentationContentInteraction(.scrolls)
    }

    // MARK: Game log

    /// Every game this season, counting or not: the latest five, then the rest on request.
    /// While the regular season is under five games old, his preseason games follow, dimmed.
    @ViewBuilder
    private var recentSection: some View {
        Section {
            if let recent {
                if recent.isEmpty && preseason.isEmpty {
                    Text("No games played yet this season").foregroundStyle(.secondary)
                } else {
                    ForEach(showAllGames ? recent : Array(recent.prefix(5))) { recentRow($0) }
                    if recent.count > 5 {
                        Button(showAllGames ? "Show fewer" : "Show all \(recent.count) games") {
                            withAnimation(.easeInOut(duration: 0.15)) { showAllGames.toggle() }
                        }
                        .font(.subheadline)
                    }
                    if recent.count < 5 && !preseason.isEmpty {
                        Text("PRESEASON").font(.caption2.bold()).foregroundStyle(.secondary)
                        ForEach(preseason) { recentRow($0).opacity(0.6) }
                    }
                }
            } else if recentFailed {
                Text("Couldn't load recent games").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading...").foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("GAME LOG")
                Spacer()
                if let avg = averageText { Text((formEmoji.map { $0 + " " } ?? "") + avg) }
            }
        }
    }

    /// The form badge and average in the header look at his latest five games only.
    private var lastFive: [RecentGame]? { recent.map { Array($0.prefix(5)) } }

    private var averageText: String? {
        guard let recent = lastFive else { return nil }
        let pts = recent.compactMap { $0.points }
        guard !pts.isEmpty else { return nil }
        let avg = Double(pts.reduce(0, +)) / Double(pts.count)
        return "\(pts.count)-game avg \(String(format: "%.1f", avg)) pts"
    }

    /// Needs 2+ games. Hot/cold by scoring average (30+ is where the bonus starts), plus a trend arrow when there are 4+.
    private var formEmoji: String? {
        guard let recent = lastFive else { return nil }
        let pts = recent.compactMap { $0.points }   // newest first
        guard pts.count >= 2 else { return nil }
        let avg = Double(pts.reduce(0, +)) / Double(pts.count)
        var out = ""
        if avg >= 30 { out = "\u{1F525}\u{1F525}" } else if avg >= 22 { out = "\u{1F525}" } else if avg < 10 { out = "\u{1F9CA}" }
        if pts.count >= 4 {
            let lastTwo = Double(pts.prefix(2).reduce(0, +)) / 2
            let earlier = Double(pts.dropFirst(2).reduce(0, +)) / Double(pts.count - 2)
            if lastTwo - earlier >= 5 { out += "\u{1F4C8}" } else if earlier - lastTwo >= 5 { out += "\u{1F4C9}" }
        }
        return out.isEmpty ? nil : out
    }

    private func gameEmoji(_ pts: Int?) -> String {
        guard let pts else { return "" }
        if pts >= 40 { return "\u{1F680} " }   // rocket: +5 bonus
        if pts >= 30 { return "\u{1F525} " }   // fire: +2 bonus
        if pts == 0 { return "\u{1F634} " }    // sleeping: DNP or goose egg
        if pts <= 8 { return "\u{1F9CA} " }    // ice
        return ""
    }

    private func recentRow(_ game: RecentGame) -> some View {
        var parts: [String] = []
        if let fg = game.fg { parts.append("\(fg) FG") }
        if let reb = game.reb { parts.append("\(reb) reb") }
        if let ast = game.ast { parts.append("\(ast) ast") }
        if let min = game.minutes { parts.append("\(min) min") }
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(game.opponent + (game.result.map { " - \($0)" } ?? ""))
                    .font(.subheadline.weight(.semibold))
                Text(game.date.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(gameEmoji(game.points) + (game.points.map(String.init) ?? "-")).font(.title3.bold()).monospacedDigit()
                Text(parts.joined(separator: " - "))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func loadRecent(force: Bool = false) async {
        var games: [RecentGame] = []
        if let id = player.espnID, let log = try? await ESPNClient.shared.gameLog(athleteID: id, force: force) {
            games = log.games
            preseason = log.preseason
            seasonPPG = log.seasonPPG
        }
        // ESPN's game log can lag early in the season; fall back to games already saved in this app.
        if games.isEmpty { games = week.savedGames(for: player.id) }
        recent = games
    }

    // MARK: News

    @ViewBuilder
    private var newsSection: some View {
        Section("Recent news") {
            if let news {
                if news.isEmpty {
                    Text("No news in the past week").foregroundStyle(.secondary)
                } else {
                    ForEach(news) { newsRow($0) }
                }
            } else if newsFailed {
                Text("Couldn't load news").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading...").foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Headline always; tap to show the full fantasy take under it.
    private func newsRow(_ item: PlayerNews) -> some View {
        let expanded = expandedNews.contains(item.id)
        return VStack(alignment: .leading, spacing: 4) {
            Text(item.headline).font(.subheadline.weight(.semibold))
            if let story = item.story {
                Text(story)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 2)
            }
            Text(item.published.formatted(.relative(presentation: .named)))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            guard item.story != nil else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                if expanded { expandedNews.remove(item.id) } else { expandedNews.insert(item.id) }
            }
        }
    }

    private func loadNews(force: Bool = false) async {
        guard let id = player.espnID else {
            news = []
            return
        }
        do {
            news = try await ESPNClient.shared.news(athleteID: id, force: force)
            newsFailed = false
        } catch {
            newsFailed = true
        }
    }
}
