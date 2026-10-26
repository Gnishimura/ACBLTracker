import SwiftUI

struct NightlyView: View {
    @EnvironmentObject var week: WeekStore
    @EnvironmentObject var directory: PlayerDirectory
    @State private var selectedDay: Date = ET.startOfDay(Date())

    /// The day actually shown: the picked day if it's in this week, else today, else the week's first day.
    private var day: Date {
        if week.days.contains(selectedDay) { return selectedDay }
        let today = ET.startOfDay(Date())
        return week.days.contains(today) ? today : week.weekStart
    }

    var body: some View {
        NavigationStack {
            let rows = week.rows(on: day)
            List {
                Section { dayStrip }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))

                if rows.isEmpty {
                    Section {
                        Text(week.results == nil
                             ? "Loading..."
                             : "None of your players have a counting game on this date.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        summary(rows)
                    }
                    Section("Players") {
                        ForEach(rows) { row in
                            NightRowView(row: row)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.bottom, 80, for: .scrollContent)
            .navigationTitle("Nightly")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { WeekNavigator() } }
            .refreshable {
                // Run in its own task so a SwiftUI redraw mid-pull can't cancel the network calls.
                await Task { await week.refresh() }.value
            }
        }
    }

    private var dayStrip: some View {
        HStack(spacing: 4) {
            ForEach(week.days, id: \.self) { d in
                let isSelected = d == day
                let total = week.nightTotal(on: d)
                Button { selectedDay = d } label: {
                    VStack(spacing: 2) {
                        Text(ET.format("EEE", d).uppercased()).font(.caption2.bold())
                        Text(ET.format("d", d)).font(.headline)
                        Text(total > 0 ? "\(total)" : "-")
                            .font(.caption2).monospacedDigit()
                            .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func summary(_ rows: [NightRow]) -> some View {
        let counted = rows.filter { $0.result.isCounted }
        let total = counted.reduce(0) { $0 + $1.result.total }
        let bonus = counted.reduce(0) { $0 + $1.result.bonus }
        return HStack {
            VStack(alignment: .leading) {
                Text(ET.format("EEEE, MMM d", day)).font(.subheadline.bold())
                Text("\(counted.count) counting, \(rows.count - counted.count) not counting")
                    .font(.caption).foregroundStyle(.secondary)
                let live = rows.filter { $0.line.state == .live }.count
                let finals = rows.filter { $0.line.state == .final }.count
                let upcoming = rows.filter { $0.line.state == .scheduled }.count
                if live == 0 && upcoming == 0 {
                    Label("All games final", systemImage: "checkmark.circle.fill")
                        .font(.caption.bold()).foregroundStyle(.green)
                } else {
                    Text([live > 0 ? "\(live) live" : nil,
                          finals > 0 ? "\(finals) final" : nil,
                          upcoming > 0 ? "\(upcoming) upcoming" : nil]
                            .compactMap { $0 }.joined(separator: ", ") + " - total can still change")
                        .font(.caption.bold()).foregroundStyle(.orange)
                }
            }
            Spacer()
            if bonus > 0 {
                Text("+\(bonus) bonus").font(.caption.bold()).foregroundStyle(.orange)
            }
            Text("\(total)")
                .font(.system(size: 34, weight: .heavy, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText(value: Double(total)))
                .animation(.snappy, value: total)
        }
    }
}

struct NightRowView: View {
    let row: NightRow
    @EnvironmentObject var directory: PlayerDirectory
    @EnvironmentObject var week: WeekStore

    var body: some View {
        let display = directory.display(for: row.player)
        let injury = week.injury(for: row.player)
        HStack(spacing: 10) {
            HeadshotView(url: display.headshot, teamColor: display.teamColor)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    PlayerName(name: row.player.name)
                    if injury != nil { InjuryMark() }
                    SeasonPPG(espnID: row.player.espnID)
                }
                HStack(spacing: 6) {
                    PositionPill(position: row.player.position)
                    TeamTag(display: display)
                    Text(row.line.opponent).font(.caption).foregroundStyle(.secondary)
                }
                if let injury {
                    Text(injury.summary).font(.caption2.weight(.semibold)).foregroundStyle(.red)
                }
                if let roleCaption {
                    Text(roleCaption).font(.caption2).foregroundStyle(roleColor)
                }
                if row.result.availability == .played(0) {
                    Text("Played - scored 0").font(.caption2.bold()).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ScoreCell(line: row.line, result: row.result)
        }
        .opacity(row.result.isCounted || row.result.availability.isDNP ? 1 : 0.55)
    }

    /// Only says something when it's out of the ordinary. Starters, playing subs (the score cell shows "counts N"),
    /// plain deep-bench rows (dimmed) and DNPs (red tag) already speak for themselves.
    private var roleCaption: String? {
        let r = row.result
        switch r.role {
        case .promoted:
            return "Moved up to starters - full points + bonus"
        case .notCounted:
            if !r.availability.isDNP && r.rawPoints >= 30 {
                return "Not counting this game (would have been a \(r.rawPoints)-point bonus game)"
            }
            return nil
        case .starter, .playingSub:
            return nil
        }
    }

    private var roleColor: Color {
        switch row.result.role {
        case .starter, .promoted: return .blue
        case .playingSub: return .secondary
        case .notCounted: return row.result.availability.isDNP ? .red : .secondary
        }
    }
}
