import SwiftUI

struct WeekNavigator: View {
    @EnvironmentObject var week: WeekStore

    var body: some View {
        HStack(spacing: 12) {
            Button { week.shiftWeek(by: -1) } label: { Image(systemName: "chevron.left") }
            VStack(spacing: 0) {
                Text("\(ET.format("MMM d", week.weekStart)) - \(ET.format("MMM d", week.weekEnd))")
                    .font(.subheadline.bold())
                HStack(spacing: 6) {
                    Text(week.weekLabel)
                        .foregroundStyle(.secondary)
                    if !week.isCurrentWeek {
                        Button { week.goToCurrentWeek() } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Back to this week")
                        .transition(.opacity)
                    }
                }
                .font(.caption2)
                .animation(.easeInOut(duration: 0.15), value: week.isCurrentWeek)
            }
            Button { week.shiftWeek(by: 1) } label: { Image(systemName: "chevron.right") }
        }
    }
}

struct WeekSummaryCard: View {
    @EnvironmentObject var week: WeekStore
    @EnvironmentObject var lineupStore: LineupStore
    var onEditName: () -> Void = {}

    /// Ebony, to match the cup. The card is dark in light mode too, so its text is forced to the dark scheme.
    private var ebony: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.12, green: 0.10, blue: 0.09), Color(red: 0.21, green: 0.17, blue: 0.13)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Button(action: onEditName) {
                    HStack(spacing: 6) {
                        Text(lineupStore.lineup.teamName)
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Image(systemName: "pencil")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                headerStatus
            }

            HStack(alignment: .top, spacing: 0) {
                stat("WEEK", week.results?.weekTotal, weight: .heavy, tint: .accentColor)
                stat("GAME 1", week.results?.gameTotal(0))
                stat("GAME 2", week.results?.gameTotal(1))
                stat("BONUS", week.results?.bonusTotal, tint: .orange)
            }

            notice

            if lineupStore.isEditable || week.regretTotal > 0 {
                Divider().overlay(Color.white.opacity(0.08))
                // One row when it fits, stacked when it doesn't.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { pills }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) { pills }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .background(ebony, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var pills: some View {
        if lineupStore.isEditable { DeadlinePill() }
        if week.regretTotal > 0 {
            SummaryPill(icon: "exclamationmark.circle", text: "\(week.regretTotal) pts left on bench", tint: .orange)
        }
    }

    /// Top right of the card: Live, or when the scores were last loaded.
    @ViewBuilder
    private var headerStatus: some View {
        HStack(spacing: 6) {
            if week.hasLive {
                LiveDot(size: 7)
                Text("Live").font(.caption.bold())
            } else if !week.isFrozen, week.errorMessage == nil, let updated = week.lastUpdated {
                Text((week.isStale ? "Saved " : "") + updatedStamp(updated))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if week.isLoading { ProgressView().controlSize(.small) }
        }
    }

    /// Only shown when something is off: finished week, no connection, or a past week.
    @ViewBuilder
    private var notice: some View {
        if week.isFrozen {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                Text("Final - saved on this phone").font(.caption).foregroundStyle(.secondary)
            }
        } else if let error = week.errorMessage {
            if week.results != nil, let saved = week.lastUpdated {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash").font(.caption).foregroundStyle(.orange)
                    Text("Can't reach ESPN. Showing scores from \(updatedStamp(saved)).")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } else if !lineupStore.isEditable {
            Text("Past week - view only").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// All four numbers share one size. The week total is the heaviest and gold.
    private func stat(_ title: String, _ value: Int?, weight: Font.Weight = .semibold, tint: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(value.map(String.init) ?? "-")
                .font(.system(size: 30, weight: weight, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText(value: Double(value ?? 0)))
                .animation(.snappy, value: value)
        }
        .frame(maxWidth: .infinity)
    }
}

struct LineupRow: View {
    let player: RosterPlayer
    let slot: SlotID
    let selected: Bool
    let editing: Bool

    @EnvironmentObject var directory: PlayerDirectory
    @EnvironmentObject var week: WeekStore

    var body: some View {
        if player.isEmpty {
            emptyRow
        } else {
            filledRow
        }
    }

    private var slotHint: String {
        switch slot {
        case .starter: return "Starter spot - tap to add"
        case .bench: return "Bench - tap to add"
        case .deep: return "Deep bench - tap to add"
        }
    }

    private var emptyRow: some View {
        HStack(spacing: 10) {
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                .foregroundStyle(.tertiary)
                .frame(width: 42, height: 42)
                .overlay(Image(systemName: "plus").foregroundStyle(.secondary))
            VStack(alignment: .leading, spacing: 3) {
                Text("Empty slot").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if slot.isStarter { PositionPill(position: player.position) }
                    Text(slotHint).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .listRowBackground(selected ? Color.accentColor.opacity(0.18) : nil)
    }

    @ViewBuilder
    private var filledRow: some View {
        let display = directory.display(for: player)
        let r0 = week.results?.result(for: player.id, game: 0)
        let r1 = week.results?.result(for: player.id, game: 1)
        let counted = (r0?.isCounted ?? true) || (r1?.isCounted ?? true)
        let injury = week.injury(for: player)
        let hot = (r0?.bonus ?? 0) > 0 || (r1?.bonus ?? 0) > 0
        let rowTint: Color? = selected ? Color.accentColor.opacity(0.18) : (hot ? Color.orange.opacity(0.10) : nil)

        HStack(spacing: 10) {
            HeadshotView(url: display.headshot, size: 42, teamColor: display.teamColor)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    PlayerName(name: player.name)
                    if injury != nil { InjuryMark() }
                    SeasonPPG(espnID: player.espnID)
                }
                HStack(spacing: 6) {
                    PositionPill(position: player.position)
                    TeamTag(display: display)
                    if !display.linked {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if let injury {
                    Text(injury.summary).font(.caption2.weight(.semibold)).foregroundStyle(.red)
                }
                promotionNote(r0, r1)
                if let note = week.regretNote(for: player.id) {
                    Text(note).font(.caption2).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ScoreCell(line: week.results?.line(for: player.id, game: 0), result: r0, loading: week.results == nil && week.isLoading)
            ScoreCell(line: week.results?.line(for: player.id, game: 1), result: r1, loading: week.results == nil && week.isLoading)
        }
        .opacity(counted ? 1 : 0.55)
        .padding(.vertical, 2)
        .listRowBackground(rowTint)
    }

    @ViewBuilder
    private func promotionNote(_ r0: PlayerGameResult?, _ r1: PlayerGameResult?) -> some View {
        if r0?.role == .promoted || r1?.role == .promoted {
            Text("Moved up to starters").font(.caption2).foregroundStyle(.blue)
        } else if !directory.display(for: player).linked {
            Text("Not matched to an NBA player - swipe to replace").font(.caption2).foregroundStyle(.orange)
        }
    }
}

struct LineupView: View {
    @EnvironmentObject var lineupStore: LineupStore
    @EnvironmentObject var week: WeekStore
    @EnvironmentObject var directory: PlayerDirectory

    @AppStorage(Reminders.storageKey) private var remindersOn = true
    @AppStorage(LineupEmail.promptKey) private var emailPrompt = true
    @State private var editing = false
    @State private var editStartOrder: [UUID]?
    @State private var showEmail = false
    @State private var selected: SlotID?
    @State private var replacing: SlotID?
    @State private var detail: RosterPlayer?
    @State private var showSwapError = false
    @State private var query = ""
    @State private var adding: DirectoryPlayer?
    @State private var renaming = false
    @State private var draftName = ""
    @State private var confirmClear = false
    @State private var moveTick = 0
    @State private var errorTick = 0
    @State private var addTick = 0

    var body: some View {
        NavigationStack {
            List {
                if !query.isEmpty {
                    searchSection
                } else {
                    Section {
                        WeekSummaryCard(onEditName: startRename)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }

                    if lineupStore.lineup.isEmpty {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Build your roster").font(.headline)
                                Text("Use the search bar above to find NBA players and add them. Starters take G, G, F, F, C, then 3 bench and 6 deep bench.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    if editing && lineupStore.isEditable {
                        reorderSection
                    } else {
                        slotSection(
                            "Starters", slots: (0..<5).map { SlotID.starter($0) }
                        )
                        slotSection(
                            "Bench", slots: (0..<3).map { SlotID.bench($0) }
                        )
                        slotSection(
                            "Deep bench", slots: (0..<6).map { SlotID.deep($0) }
                        )
                        totalsSection
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.bottom, 80, for: .scrollContent)   // keeps the last row clear of the floating tab bar
            .environment(\.editMode, .constant(listEditMode))
            .navigationTitle(lineupStore.lineup.teamName)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .automatic),   // scrolls away; pull down to bring it back
                prompt: "Add a player"
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if lineupStore.isEditable {
                        Button(editing ? "Done" : "Edit") {
                            if editing {
                                finishEditing()
                            } else {
                                editStartOrder = lineupStore.lineup.all.map(\.id)
                                editing = true
                            }
                            selected = nil
                        }
                    }
                }
                ToolbarItem(placement: .principal) { WeekNavigator() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Rename team", systemImage: "pencil") { startRename() }
                        Button(remindersOn ? "Turn off reminders" : "Turn on reminders",
                               systemImage: remindersOn ? "bell.slash" : "bell") {
                            remindersOn.toggle()
                            Task { await Reminders.sync(enabled: remindersOn) }
                        }
                        if lineupStore.isEditable {
                            Button("Email lineup", systemImage: "envelope") { showEmail = true }
                            Button("Clear this week's lineup", systemImage: "trash", role: .destructive) {
                                confirmClear = true
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: moveTick)
            .sensoryFeedback(.error, trigger: errorTick)
            .sensoryFeedback(.success, trigger: addTick)
            .sensoryFeedback(.selection, trigger: selected)
            .refreshable {
                // Run in its own task so a SwiftUI redraw mid-pull can't cancel the network calls.
                await Task { await week.refreshAll() }.value
            }
            .alert("Can't swap those", isPresented: $showSwapError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("A starter spot only takes the position it's set for (G, G, F, F, C).")
            }
            .alert("Team name", isPresented: $renaming) {
                TextField("Team name", text: $draftName)
                Button("Save") { lineupStore.rename(draftName) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Clear this week's lineup?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear lineup", role: .destructive) { lineupStore.clearAll() }
            }
            .onChange(of: lineupStore.isEditable) { _, editable in
                if !editable {
                    editing = false
                    editStartOrder = nil
                    selected = nil
                }
            }
            .sheet(isPresented: $showEmail) {
                LineupEmailSheet()
            }
            .sheet(item: $replacing) { slot in
                PlayerPickerView(slot: slot)
            }
            .sheet(item: $detail) { player in
                PlayerDetailView(player: player)
            }
            .sheet(item: $adding) { player in
                AddPlayerView(player: player) {
                    query = ""
                    addTick += 1
                }
            }
        }
    }

    // MARK: Search results

    @ViewBuilder
    private var searchSection: some View {
        if !lineupStore.isEditable {
            Section {
                Text("Past weeks are view only. Jump to this week or a future week to add players.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } else {
            searchResults
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = directory.search(query)
        Section(searchTitle(resultCount: results.count)) {
            ForEach(results) { p in
                let onRoster = lineupStore.lineup.contains(espnID: p.id)
                let display = directory.display(for: p)
                Button { adding = p } label: {
                    HStack(spacing: 10) {
                        HeadshotView(url: display.headshot, size: 40, teamColor: display.teamColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.name).font(.subheadline.weight(.semibold))
                            TeamTag(display: display)
                        }
                        Spacer()
                        if onRoster {
                            Label("On roster", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        } else {
                            Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(onRoster)
            }
        }
    }

    private func searchTitle(resultCount: Int) -> String {
        if !directory.isLoaded { return "Loading NBA players..." }
        if query.normalizedName.count < 2 { return "Type at least 2 letters" }
        return resultCount == 0 ? "No NBA players found" : "Tap a player to add"
    }

    // MARK: Roster sections

    private func slotSection(_ title: String, slots: [SlotID]) -> some View {
        Section {
            ForEach(slots) { slot in
                let p = lineupStore.lineup.player(at: slot)
                let row = Button { tap(slot) } label: {
                    LineupRow(
                        player: p, slot: slot,
                        selected: selected == slot,
                        editing: editing
                    )
                }
                .buttonStyle(.plain)

                if lineupStore.isEditable {
                    row
                        .swipeActions(edge: .trailing) {
                            if !p.isEmpty {
                                Button("Remove", role: .destructive) { lineupStore.remove(slot: slot) }
                            }
                            Button(p.isEmpty ? "Add" : "Replace") { replacing = slot }.tint(.blue)
                        }
                } else {
                    row
                }
            }
        } header: {
            HStack {
                Text(title.uppercased())
                Spacer()
                Text("G1").frame(width: Col.game)
                Text("G2").frame(width: Col.game)
            }
        }
    }

    /// Team totals for each of the two games, lined up under the G1 / G2 columns.
    private var totalsSection: some View {
        Section {
            HStack {
                Text("Counted points").font(.subheadline.weight(.semibold))
                Spacer()
                totalCell(week.results.map { $0.gameTotal(0) })
                totalCell(week.results.map { $0.gameTotal(1) })
            }
        } header: {
            HStack {
                Text("TEAM TOTAL")
                Spacer()
                Text("G1").frame(width: Col.game)
                Text("G2").frame(width: Col.game)
            }
        }
    }

    private func totalCell(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "-")
            .font(.title3.bold())
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(value ?? 0)))
            .animation(.snappy, value: value)
            .frame(width: Col.game)
    }

    // MARK: Edit mode: drag the handles to reorder across sections

    private enum EditItem: Identifiable {
        case header(String)
        case slot(SlotID)

        var id: String {
            switch self {
            case .header(let title): return "header-\(title)"
            case .slot(let slot): return slot.payload
            }
        }
    }

    /// One flat list so a row can be dragged from Starters to Bench to Deep bench. Headers are rows that can't be moved.
    private var editItems: [EditItem] {
        var items: [EditItem] = [.header("Starters")]
        for i in 0..<5 { items.append(.slot(.starter(i))) }
        items.append(.header("Bench"))
        for i in 0..<3 { items.append(.slot(.bench(i))) }
        items.append(.header("Deep bench"))
        for i in 0..<6 { items.append(.slot(.deep(i))) }
        return items
    }

    private var reorderSection: some View {
        Section {
            ForEach(editItems) { item in
                switch item {
                case .header(let title):
                    HStack {
                        Text(title.uppercased())
                        Spacer()
                        Text("G1").frame(width: Col.game)
                        Text("G2").frame(width: Col.game)
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .moveDisabled(true)
                case .slot(let slot):
                    Button { tap(slot) } label: {
                        LineupRow(
                            player: lineupStore.lineup.player(at: slot), slot: slot,
                            selected: selected == slot,
                            editing: true
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .onMove(perform: reorder)
        }
    }

    private var listEditMode: EditMode {
        (editing && lineupStore.isEditable && query.isEmpty) ? .active : .inactive
    }

    /// SwiftUI reports "item at `source` was dropped before row `destination`". We turn that into the lineup's own
    /// move rule: anything involving a starter spot swaps, bench and deep bench re-order by insertion.
    private func reorder(from source: IndexSet, to destination: Int) {
        let items = editItems
        guard let s = source.first, s < items.count, case .slot(let from) = items[s] else { return }
        let downward = destination > s
        let f = min(max(downward ? destination - 1 : destination, 0), items.count - 1)

        var target: SlotID?
        switch items[f] {
        case .slot(let t):
            target = t
        case .header:
            // Dropped on a section header: use the nearest player row in the direction of travel.
            let candidates = downward ? Array((f + 1)..<items.count) : Array((0..<f).reversed())
            for i in candidates {
                if case .slot(let t) = items[i] {
                    target = t
                    break
                }
            }
        }
        guard let target, target != from else { return }

        if lineupStore.move(from: from, to: target) {
            moveTick += 1
        } else {
            errorTick += 1
            showSwapError = true
        }
    }

    /// Leaving edit mode. If the order actually changed, offer to draft the lineup email.
    /// Compared by player id, so a background ESPN match during editing doesn't count as a change.
    private func finishEditing() {
        editing = false
        defer { editStartOrder = nil }
        guard emailPrompt, let before = editStartOrder, before != lineupStore.lineup.all.map(\.id) else { return }
        showEmail = true
    }

    private func startRename() {
        draftName = lineupStore.lineup.teamName
        renaming = true
    }

    private func tap(_ slot: SlotID) {
        let tapped = lineupStore.lineup.player(at: slot)
        // Outside edit mode, tapping a player opens his stat sheet (past weeks included).
        if !editing, !tapped.isEmpty {
            detail = tapped
            return
        }
        guard lineupStore.isEditable else { return }
        guard editing else {
            if tapped.isEmpty { replacing = slot }   // tap an empty slot to fill it
            return
        }
        guard let first = selected else {
            selected = slot
            return
        }
        if first == slot {
            selected = nil
            return
        }
        if lineupStore.exchange(first, slot) {
            moveTick += 1
        } else {
            errorTick += 1
            showSwapError = true
        }
        selected = nil
    }
}
