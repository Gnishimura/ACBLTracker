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
                             : "None of your players play on this date.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    let counting = rows.filter { !$0.isOffNight }
                    let off = rows.filter(\.isOffNight)
                    Section {
                        summary(rows)
                    }
                    if !counting.isEmpty {
                        Section {
                            ForEach(counting) { row in
                                NightRowView(row: row)
                            }
                        } header: {
                            Label("Counting games", systemImage: "checkmark.circle.fill")
                        }
                    }
                    if !off.isEmpty {
                        Section {
                            ForEach(off) { row in
                                NightRowView(row: row)
                            }
                        } header: {
                            Label("Off night", systemImage: "moon.zzz.fill")
                        } footer: {
                            Text("These teams already played their 2 counting games this week, so these points don't count.")
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
                await Task { await week.refreshAll() }.value
            }
        }
    }

    private var dayStrip: some View {
        HStack(spacing: 4) {
            ForEach(week.days, id: \.self) { d in
                let isSelected = d == day
                let total = week.nightTotal(on: d)
                let dayRows = week.rows(on: d)
                let offOnly = !dayRows.isEmpty && dayRows.allSatisfy(\.isOffNight)
                Button { selectedDay = d } label: {
                    VStack(spacing: 2) {
                        Text(ET.format("EEE", d).uppercased()).font(.caption2.bold())
                        Text(ET.format("d", d)).font(.headline)
                        Text(total > 0 ? "\(total)" : offOnly ? "off" : "-")
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
        let off = rows.filter(\.isOffNight).count
        let notCounted = rows.count - counted.count - off
        return HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text(ET.format("EEEE, MMM d", day)).font(.subheadline.bold())
                    NightKindTag(offNight: off == rows.count)
                }
                Text([counted.count > 0 || notCounted > 0 ? "\(counted.count) counting" : nil,
                      notCounted > 0 ? "\(notCounted) not counting" : nil,
                      off > 0 ? "\(off) off night" : nil]
                        .compactMap { $0 }.joined(separator: ", "))
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

/// "Counting night" when any of your games tonight count, "Off night" when none can.
struct NightKindTag: View {
    let offNight: Bool

    var body: some View {
        Text(offNight ? "OFF NIGHT" : "COUNTING NIGHT")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(offNight ? Color.secondary : Color.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((offNight ? Color.secondary : Color.green).opacity(0.15), in: Capsule())
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
        .opacity(row.result.isCounted || row.result.availability.isDNP ? 1 : row.isOffNight ? 0.75 : 0.55)
    }

    /// Only says something when it's out of the ordinary. Starters, playing subs (the score cell shows "counts N"),
    /// plain deep-bench rows (dimmed) and DNPs (red tag) already speak for themselves.
    private var roleCaption: String? {
        let r = row.result
        if row.isOffNight { return "Game \(row.gameIndex + 1) of the week - doesn't count" }
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
