import SwiftUI

/// Column widths shared by the lineup header, rows and score cells so they line up.
enum Col {
    static let game: CGFloat = 46
    static let total: CGFloat = 34
}

extension Color {
    /// Team color from ESPN's hex ("c8102e"). Near-black and near-white become grey so the ring shows in light and dark mode.
    static func team(hex: String?) -> Color? {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if luminance < 0.16 || luminance > 0.9 { return Color(white: 0.55) }
        return Color(red: r, green: g, blue: b)
    }
}

/// "9:12 PM" for today, "Tue 9:12 PM" otherwise.
func updatedStamp(_ d: Date) -> String {
    if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
    return d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

extension String {
    /// "Jalen Brunson" -> "J. Brunson". Single-word names are returned unchanged.
    var abbreviatedName: String {
        let parts = split(separator: " ").map(String.init)
        guard parts.count >= 2, let initial = parts.first?.first else { return self }
        return "\(initial). " + parts.dropFirst().joined(separator: " ")
    }
}

/// Full name when it fits, "J. Brunson" when it doesn't, shrinking slightly as a last resort. Never "...".
struct PlayerName: View {
    let name: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(name).lineLimit(1)
            Text(name.abbreviatedName).lineLimit(1).minimumScaleFactor(0.7)
        }
        .font(.subheadline.weight(.semibold))
    }
}

struct HeadshotView: View {
    let url: URL?
    var size: CGFloat = 48
    /// Team color hex. Not drawn right now (the rings were removed); kept so call sites don't change.
    var teamColor: String? = nil

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size, alignment: .top)
                    .clipped()
            default:
                Image(systemName: "person.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.24)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color(.tertiarySystemFill))
        .clipShape(Circle())
    }
}

struct TeamTag: View {
    let display: PlayerDisplay

    var body: some View {
        HStack(spacing: 4) {
            AsyncImage(url: display.teamLogo) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                } else {
                    Color.clear
                }
            }
            .frame(width: 16, height: 16)
            Text(display.teamAbbr)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct PositionPill: View {
    let position: Position

    var body: some View {
        Text(position.rawValue)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 19, height: 16)
            .background(Color(.quaternarySystemFill), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Green dot that slowly pulses while a game is live.
struct LiveDot: View {
    var size: CGFloat = 5
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: size, height: size)
            .opacity(dim ? 0.3 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// Red + beside a name when the player is on ESPN's injury report.
struct InjuryMark: View {
    var body: some View {
        Image(systemName: "cross.fill")
            .font(.system(size: 12, weight: .heavy))
            .foregroundStyle(.red)
            .accessibilityLabel("Injured")
    }
}

/// "+2" for 30-39 point games, "+5" for 40+.
struct BonusBadge: View {
    let bonus: Int
    /// Small "+2" chip with no flame, sized to sit beside the points without changing the row height.
    var compact: Bool = false

    var body: some View {
        if bonus > 0 {
            HStack(spacing: 2) {
                if !compact { Image(systemName: bonus >= 5 ? "flame.fill" : "flame") }
                Text("+\(bonus)")
            }
            .font(compact ? .system(size: 10, weight: .heavy) : .caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, compact ? 1 : 2)
            .background(bonus >= 5 ? Color.red : Color.orange, in: Capsule())
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }
}

/// One game cell: points, bonus badge, or DNP / start time.
struct ScoreCell: View {
    let line: GameLine?
    let result: PlayerGameResult?
    /// True while the very first load is running: shows a grey block instead of "-".
    var loading: Bool = false

    var body: some View {
        VStack(spacing: 2) {
            if loading && line == nil {
                Text("00")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .redacted(reason: .placeholder)
            } else if let line, let result {
                content(line: line, result: result)
                // Only live games (and OT finals) need a status line. A plain "Final" on every row is noise.
                if line.state == .live || (line.state == .final && line.statusText.contains("/")), !line.statusText.isEmpty {
                    Text(line.statusText)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(line.state == .live ? Color.green : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } else {
                Text("-").foregroundStyle(.tertiary)
            }
        }
        .frame(width: Col.game)
        .animation(.snappy, value: result?.total)
    }

    private func dayAndTime(_ d: Date) -> (day: String, time: String) {
        let day = DateFormatter()
        day.dateFormat = "EEE"
        let time = DateFormatter()
        time.dateFormat = "h:mm a"
        return (day.string(from: d), time.string(from: d))
    }

    @ViewBuilder
    private func content(line: GameLine, result: PlayerGameResult) -> some View {
        switch result.availability {
        case .dnp:
            // Did not play: a red tag, no number at all.
            Text("DNP")
                .font(.caption.bold())
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.15), in: Capsule())
        case .pending:
            if line.state == .scheduled {
                let t = dayAndTime(line.date)
                Text(t.day).font(.caption2.bold()).foregroundStyle(.secondary)
                Text(t.time).font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text("...").foregroundStyle(.secondary)
            }
        case .live(let pts), .played(let pts):
            // Played a full game and scored nothing: orange 0 with a "played" tag, so it can't be mistaken for a DNP.
            let playedZero = pts == 0 && line.state == .final
            HStack(spacing: 2) {
                if line.state == .live {
                    LiveDot(size: 5)
                }
                Text("\(pts)")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(pts)))
                    .foregroundStyle(playedZero ? Color.orange : (result.isCounted ? Color.primary : Color.secondary))
            }
            .overlay(alignment: .topTrailing) {
                BonusBadge(bonus: result.bonus, compact: true)
                    .offset(x: 18, y: -6)
            }
            if let made = line.fgm, let att = line.fga {
                Text("\(made)-\(att)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if playedZero {
                Text("played")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            if result.role == .playingSub {
                Text("counts \(result.countedPoints)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

/// Full box score for a game (live or final): a team switch, a pinned name column, and stat columns that scroll sideways.
/// The tracked player's row is tinted so he's easy to find.
struct LiveBoxScoreView: View {
    let box: FullBox
    /// ESPN athlete id of the player whose detail screen this is.
    let highlightID: String?
    /// His team's ESPN id. That team is shown first.
    let teamID: String?

    @State private var picked: String?

    private static let columns = ["MIN", "PTS", "FG", "3PT", "FT", "REB", "AST", "STL", "BLK", "TO", "PF", "+/-"]
    private let rowHeight: CGFloat = 26
    private let nameWidth: CGFloat = 96

    private func width(_ label: String) -> CGFloat {
        switch label {
        case "FG", "3PT", "FT": return 46
        case "MIN", "PTS": return 38
        default: return 34
        }
    }

    private var statsWidth: CGFloat { Self.columns.reduce(0) { $0 + width($1) } }

    private var team: TeamBox? {
        let id = picked ?? teamID
        return box.teams.first { $0.id == id } ?? box.teams.first
    }

    var body: some View {
        VStack(spacing: 10) {
            if box.teams.count > 1 {
                Picker("Team", selection: Binding(get: { team?.id ?? "" }, set: { picked = $0 })) {
                    ForEach(box.teams) { Text($0.abbr).tag($0.id) }
                }
                .pickerStyle(.segmented)
            }
            if let team { table(team) }
        }
    }

    private func table(_ team: TeamBox) -> some View {
        let indexes = Self.columns.map { team.labels.firstIndex(of: $0) }
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("PLAYER").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: nameWidth, height: rowHeight, alignment: .leading)
                ForEach(team.rows) { row in
                    Text(row.name)
                        .font(.system(size: 12, weight: row.starter ? .semibold : .regular))
                        .foregroundStyle(row.played ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: nameWidth, height: rowHeight, alignment: .leading)
                        .background(tint(row))
                }
                if !team.totals.isEmpty {
                    Text("TEAM").font(.system(size: 11, weight: .bold))
                        .frame(width: nameWidth, height: rowHeight, alignment: .leading)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(Self.columns, id: \.self) { label in
                            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                .frame(width: width(label), height: rowHeight)
                        }
                    }
                    ForEach(team.rows) { row in
                        if row.played {
                            HStack(spacing: 0) {
                                ForEach(Array(Self.columns.enumerated()), id: \.offset) { offset, label in
                                    cell(value(row.stats, indexes[offset]), label: label, bold: label == "PTS")
                                }
                            }
                            .background(tint(row))
                        } else {
                            Text(row.reason ?? "Hasn't played")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(width: statsWidth, height: rowHeight, alignment: .leading)
                                .background(tint(row))
                        }
                    }
                    if !team.totals.isEmpty {
                        HStack(spacing: 0) {
                            ForEach(Array(Self.columns.enumerated()), id: \.offset) { offset, label in
                                cell(value(team.totals, indexes[offset]), label: label, bold: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func value(_ stats: [String], _ index: Int?) -> String {
        guard let index, index < stats.count, !stats[index].isEmpty else { return "-" }
        return stats[index]
    }

    private func cell(_ text: String, label: String, bold: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: bold ? .bold : .regular).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width(label), height: rowHeight)
    }

    private func tint(_ row: BoxRow) -> Color {
        row.id == highlightID ? Color.accentColor.opacity(0.14) : Color.clear
    }
}
