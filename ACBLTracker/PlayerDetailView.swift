import SwiftUI

/// Tap a player on the Lineup tab: full stat line for each of his two counting games and how each one scored.
struct PlayerDetailView: View {
    let player: RosterPlayer
    @EnvironmentObject var week: WeekStore
    @EnvironmentObject var directory: PlayerDirectory
    @Environment(\.dismiss) private var dismiss

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
                            }
                            if let injury = week.injury(for: player) {
                                Text(injury.summary).font(.caption.weight(.semibold)).foregroundStyle(.red)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                gameSection(0)
                gameSection(1)

                if let total = week.results?.playerTotal(player.id) {
                    Section("This week") {
                        HStack {
                            Text("Points counted")
                            Spacer()
                            Text("\(total)").font(.title3.bold()).monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(player.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: One game

    @ViewBuilder
    private func gameSection(_ g: Int) -> some View {
        let line = week.results?.line(for: player.id, game: g)
        let result = week.results?.result(for: player.id, game: g)

        Section {
            if let line {
                if line.state == .scheduled {
                    HStack {
                        Text("Tips off")
                        Spacer()
                        Text(line.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    }
                } else if line.points == nil {
                    Text(result?.availability.isDNP == true ? "Did not play" : "Waiting for the box score")
                        .foregroundStyle(result?.availability.isDNP == true ? Color.red : Color.secondary)
                } else {
                    statGrid(line)
                }
                if let result, line.state != .scheduled {
                    HStack {
                        Text(roleText(result)).foregroundStyle(.secondary)
                        Spacer()
                        if result.isCounted {
                            Text(result.bonus > 0 ? "\(result.countedPoints) + \(result.bonus) bonus" : "\(result.countedPoints) counted")
                                .font(.subheadline.weight(.semibold)).monospacedDigit()
                        }
                    }
                    .font(.subheadline)
                }
            } else {
                Text("No game found for this week yet").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("GAME \(g + 1)" + (line.map { " - \($0.opponent)" } ?? ""))
                Spacer()
                if let line, line.state == .live {
                    Text(line.statusText).foregroundStyle(.green)
                } else if let line, line.state == .final {
                    Text(line.statusText)
                }
            }
        }
    }

    private func statGrid(_ line: GameLine) -> some View {
        let b = line.box
        let cells: [(String, String)] = [
            ("PTS", line.points.map(String.init) ?? "-"),
            ("MIN", b?.minutes ?? "-"),
            ("FG", pair(line.fgm, line.fga)),
            ("FG%", percent(line.fgm, line.fga)),
            ("3PT", pair(b?.tpm, b?.tpa)),
            ("FT", pair(b?.ftm, b?.fta)),
            ("REB", num(b?.reb)),
            ("AST", num(b?.ast)),
            ("STL", num(b?.stl)),
            ("BLK", num(b?.blk)),
            ("TO", num(b?.tov)),
            ("+/-", signed(b?.plusMinus)),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 16) {
            ForEach(cells, id: \.0) { cell in
                VStack(spacing: 2) {
                    Text(cell.1).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    Text(cell.0).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    private func num(_ v: Int?) -> String { v.map(String.init) ?? "-" }

    private func pair(_ made: Int?, _ att: Int?) -> String {
        guard let made, let att else { return "-" }
        return "\(made)-\(att)"
    }

    private func percent(_ made: Int?, _ att: Int?) -> String {
        guard let made, let att, att > 0 else { return "-" }
        return "\(Int((Double(made) / Double(att) * 100).rounded()))%"
    }

    private func signed(_ v: Int?) -> String {
        guard let v else { return "-" }
        return v > 0 ? "+\(v)" : "\(v)"
    }

    private func roleText(_ r: PlayerGameResult) -> String {
        switch r.role {
        case .starter: return "Starter - full points"
        case .promoted: return "Moved up to starters - full points"
        case .playingSub: return "Playing sub - half points"
        case .notCounted: return r.availability.isDNP ? "Did not play" : "Not counting this game"
        }
    }
}
