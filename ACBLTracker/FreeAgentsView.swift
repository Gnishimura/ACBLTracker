import SwiftUI
import Combine

/// Free agents worth a look: every NBA player not on a league roster whose last 3 games average over 10 points.
@MainActor
final class FreeAgentStore: ObservableObject {
    struct Row: Identifiable {
        let id: String          // ESPN athlete id
        let name: String
        let position: Position  // the league's, from the Positions tab when it lists him
        let games: Int
        let last3: Double
        let last5: Double
        let season: Double
    }

    static let minimumLast3 = 10.0

    @Published private(set) var rows: [Row]?
    @Published private(set) var rosterTab: String?
    @Published private(set) var rosteredCount = 0
    @Published private(set) var unmatched: [String] = []
    @Published private(set) var gamesSaved = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?

    /// The last roster tab read, kept on the phone. `week` is the tab's own week, so while the new week's tab is
    /// still empty (Tuesday, before the commish fills it in) the app keeps checking for it.
    private struct SavedRoster: Codable {
        var week: Int
        var cells: [String]
        var positions: [String: Position]
    }
    private var roster: SavedRoster?
    private let fileURL = Storage.url("league-rosters.json")

    init() {
        if let data = try? Data(contentsOf: fileURL), let r = try? JSONDecoder().decode(SavedRoster.self, from: data) {
            roster = r
            rosterTab = "W\(r.week)"
        }
    }

    /// Reads this week's roster tab once (or again when `force`), adds any newly finished box scores, and rebuilds the list.
    func refresh(directory: PlayerDirectory, force: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        await directory.load()
        let week = WeekStore.weekNumber(for: ET.weekStart(containing: Date()))
        if force || roster?.week != week {
            await readRoster(week: week, directory: directory)
        }
        await SeasonBoxScores.shared.refresh(from: WeekStore.seasonStart)
        await rebuild(directory: directory)
    }

    /// This week's tab, or last week's while this week's is still empty.
    private func readRoster(week: Int, directory: PlayerDirectory) async {
        let matcher = RosterMatcher(players: directory.players)
        for w in [week, week - 1] where w >= 1 {
            guard let rows = try? await LeagueSheet.rows(tab: "W\(w)") else { continue }
            let cells = LeagueSheet.rosterCells(rows).filter(matcher.isPlayerCell)
            guard cells.count >= LeagueSheet.minimumRosterSize else { continue }
            let positions = (try? await LeagueSheet.positions()) ?? roster?.positions ?? [:]
            let r = SavedRoster(week: w, cells: cells, positions: positions)
            roster = r
            rosterTab = "W\(w)"
            errorText = nil
            if let data = try? JSONEncoder().encode(r) { try? data.write(to: fileURL, options: .atomic) }
            return
        }
        if roster == nil { errorText = "Couldn't read the league sheet's roster tab" }
    }

    private func rebuild(directory: PlayerDirectory) async {
        guard let roster, directory.isLoaded else { return }
        let matcher = RosterMatcher(players: directory.players)
        var rostered = Set<String>()
        var missed: [String] = []
        for cell in roster.cells {
            switch matcher.match(cell) {
            case .matched(let id): rostered.insert(id)
            case .ambiguous(let ids): rostered.formUnion(ids)
            case .unmatched: missed.append(cell)
            }
        }
        rosteredCount = rostered.count
        unmatched = missed

        let points = await SeasonBoxScores.shared.pointsByPlayer()
        gamesSaved = await SeasonBoxScores.shared.gameCount
        func avg(_ pts: ArraySlice<Int>) -> Double { Double(pts.reduce(0, +)) / Double(pts.count) }
        rows = directory.players.compactMap { p -> Row? in
            guard !rostered.contains(p.id), let pts = points[p.id], !pts.isEmpty else { return nil }
            let last3 = avg(pts.prefix(3))
            guard last3 > Self.minimumLast3 else { return nil }
            return Row(
                id: p.id, name: p.name,
                position: roster.positions[p.name.normalizedName] ?? Position.fromESPN(p.position),
                games: pts.count, last3: last3, last5: avg(pts.prefix(5)), season: avg(pts[...])
            )
        }
        .sorted { ($0.last3, $0.season) > ($1.last3, $1.season) }
    }
}

struct FreeAgentsView: View {
    @EnvironmentObject var directory: PlayerDirectory
    @StateObject private var store = FreeAgentStore()
    @State private var selected: RosterPlayer?
    @State private var showUnmatched = false

    var body: some View {
        NavigationStack {
            List {
                Section { status }

                if let rows = store.rows {
                    Section {
                        if rows.isEmpty {
                            Text("No free agents are averaging over 10 in their last 3 games").foregroundStyle(.secondary)
                        } else {
                            columnHeader
                            ForEach(rows) { row in
                                Button { selected = rosterPlayer(row) } label: { rowView(row) }
                                    .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        Text("\(rows.count) free agents averaging 10+ over their last 3")
                    }
                } else if let error = store.errorText {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading box scores... the first time takes a minute").foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.bottom, 80, for: .scrollContent)
            .navigationTitle("Free Agent Tracker")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await Task { await store.refresh(directory: directory, force: true) }.value }
            .task { await store.refresh(directory: directory) }
            .sheet(item: $selected) { PlayerDetailView(player: $0) }
        }
    }

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let tab = store.rosterTab {
                Text("Rosters from the league sheet's \(tab) tab - \(store.rosteredCount) players taken")
                    .font(.subheadline)
            }
            Text(store.gamesSaved > 0
                 ? "Stats from \(store.gamesSaved) finished games. Pull down to re-read the sheet."
                 : "Pull down to re-read the sheet.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !store.unmatched.isEmpty {
            DisclosureGroup(isExpanded: $showUnmatched) {
                ForEach(store.unmatched, id: \.self) { Text($0).font(.caption) }
            } label: {
                Label("\(store.unmatched.count) sheet names didn't match an NBA player", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
        }
    }

    private var columnHeader: some View {
        HStack {
            Text("PLAYER").frame(maxWidth: .infinity, alignment: .leading)
            Text("L3").frame(width: 40, alignment: .trailing)
            Text("L5").frame(width: 40, alignment: .trailing)
            Text("SZN").frame(width: 40, alignment: .trailing)
        }
        .font(.caption2.bold())
        .foregroundStyle(.secondary)
    }

    private func rowView(_ row: FreeAgentStore.Row) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                PlayerName(name: row.name)
                HStack(spacing: 6) {
                    PositionPill(position: row.position)
                    if let dp = directory.player(id: row.id) { TeamTag(display: directory.display(for: dp)) }
                    Text("\(row.games) GP").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "%.1f", row.last3)).bold().frame(width: 40, alignment: .trailing)
            Text(String(format: "%.1f", row.last5)).frame(width: 40, alignment: .trailing)
            Text(String(format: "%.1f", row.season)).frame(width: 40, alignment: .trailing)
        }
        .font(.subheadline).monospacedDigit()
        .contentShape(Rectangle())
    }

    private func rosterPlayer(_ row: FreeAgentStore.Row) -> RosterPlayer {
        RosterPlayer(name: row.name, position: row.position,
                     teamHint: directory.player(id: row.id)?.teamAbbr ?? "", espnID: row.id)
    }
}
