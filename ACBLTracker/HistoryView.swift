import SwiftUI
import Charts

/// Season so far: one bar per league week, plus a list of every week's totals.
struct HistoryView: View {
    @EnvironmentObject var week: WeekStore

    private var currentWeekNumber: Int {
        WeekStore.weekNumber(for: ET.weekStart(containing: Date()))
    }

    var body: some View {
        let entries = week.history()
        NavigationStack {
            List {
                if entries.isEmpty {
                    Section {
                        Text("Weeks show up here once their scores have loaded on this phone.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section { summary(entries) }
                    Section("Points by week") { chart(entries) }
                    Section("Weeks") {
                        ForEach(entries.reversed()) { row($0) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.bottom, 80, for: .scrollContent)
            .refreshable { await Task { await week.refreshAll() }.value }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Pieces

    private func average(_ entries: [WeekStore.HistoryEntry]) -> Double {
        guard !entries.isEmpty else { return 0 }
        return Double(entries.reduce(0) { $0 + $1.total }) / Double(entries.count)
    }

    private func summary(_ entries: [WeekStore.HistoryEntry]) -> some View {
        let total = entries.reduce(0) { $0 + $1.total }
        let bonus = entries.reduce(0) { $0 + $1.bonus }
        let best = entries.max { $0.total < $1.total }
        return HStack(alignment: .top, spacing: 0) {
            stat("SEASON", "\(total)", tint: .accentColor)
            stat("AVG / WEEK", "\(Int(average(entries).rounded()))")
            stat("BEST", best.map { "\($0.total)" } ?? "-", caption: best.map { "Week \($0.weekNumber)" })
            stat("BONUS", "\(bonus)", tint: .orange)
        }
        .padding(.vertical, 4)
    }

    private func stat(_ title: String, _ value: String, tint: Color = .primary, caption: String? = nil) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(caption ?? " ").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func chart(_ entries: [WeekStore.HistoryEntry]) -> some View {
        Chart {
            ForEach(entries) { e in
                BarMark(
                    x: .value("Week", "W\(e.weekNumber)"),
                    y: .value("Points", e.total)
                )
                .foregroundStyle(e.weekNumber == currentWeekNumber ? Color.accentColor.opacity(0.45) : Color.accentColor)
            }
            RuleMark(y: .value("Average", average(entries)))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.secondary)
        }
        .frame(height: 170)
        .padding(.vertical, 6)
    }

    private func row(_ e: WeekStore.HistoryEntry) -> some View {
        let start = ET.addDays(7 * (e.weekNumber - 1), to: WeekStore.seasonStart)
        let end = ET.addDays(6, to: start)
        let inProgress = e.weekNumber == currentWeekNumber
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Week \(e.weekNumber)").font(.subheadline.weight(.semibold))
                    if inProgress {
                        Text("IN PROGRESS")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.green)
                    }
                }
                Text("\(ET.format("MMM d", start)) - \(ET.format("MMM d", end))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(e.total)").font(.title3.bold()).monospacedDigit()
                Text("G1 \(e.game1) / G2 \(e.game2)" + (e.bonus > 0 ? " / +\(e.bonus) bonus" : ""))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }
}
